{-# LANGUAGE CPP #-}

module Agda.TypeChecking.Records where

import Control.Applicative
import Control.Arrow ((***))
import Control.Monad
import Data.List

import Agda.Syntax.Common
import qualified Agda.Syntax.Concrete.Name as C
import Agda.Syntax.Abstract.Name
import Agda.Syntax.Internal
import Agda.Syntax.Position
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Datatypes
import Agda.Utils.List
import Agda.Utils.Monad

#include "../undefined.h"
import Agda.Utils.Impossible

-- | Order the fields of a record construction.
--   Use the second argument for missing fields.
orderFields :: MonadTCM tcm => QName -> a -> [C.Name] -> [(C.Name, a)] -> tcm [a]
orderFields r def xs fs = do
  shouldBeNull (ys \\ nub ys) $ DuplicateFields . nub
  shouldBeNull (ys \\ xs)     $ TooManyFields r
  -- shouldBeNull (xs \\ ys)     $ TooFewFields r
  return $ order xs fs
  where
    ys = map fst fs

    shouldBeNull [] err = return ()
    shouldBeNull xs err = typeError $ err xs

    -- invariant: the first list contains at least the fields of the second list
    order [] [] = []
    order [] _  = __IMPOSSIBLE__
    order (x : xs) ys = case lookup x (assocHoles ys) of
      Just (e, ys') -> e : order xs ys'
      Nothing       -> def : order xs ys

    assocHoles xs = [ (x, (v, xs')) | ((x, v), xs') <- holes xs ]

-- | The name of the module corresponding to a record.
recordModule :: QName -> ModuleName
recordModule = mnameFromList . qnameToList

-- | Get the definition for a record. Throws an exception if the name
--   does not refer to a record.
getRecordDef :: MonadTCM tcm => QName -> tcm Defn
getRecordDef r = do
  def <- theDef <$> getConstInfo r
  case def of
    Record{} -> return def
    _        -> typeError $ ShouldBeRecordType (El Prop $ Def r [])

-- | Get the field names of a record.
getRecordFieldNames :: MonadTCM tcm => QName -> tcm [Arg C.Name]
getRecordFieldNames r =
  map (fmap (nameConcrete . qnameName)) . recFields <$> getRecordDef r

-- | Get the field types of a record.
getRecordFieldTypes :: MonadTCM tcm => QName -> tcm Telescope
getRecordFieldTypes r = recTel <$> getRecordDef r

-- | Get the type of the record constructor.
getRecordConstructorType :: MonadTCM tcm => QName -> tcm Type
getRecordConstructorType r = recConType <$> getRecordDef r

-- | Returns the given record type's constructor name (with an empty
-- range).
getRecordConstructor :: MonadTCM tcm => QName -> tcm QName
getRecordConstructor r = killRange <$> recCon <$> getRecordDef r

-- | Check if a name refers to a record.
isRecord :: MonadTCM tcm => QName -> tcm Bool
isRecord r = do
  def <- theDef <$> getConstInfo r
  return $ case def of
    Record{} -> True
    _        -> False

-- | Check if a name refers to an eta expandable record.
isEtaRecord :: MonadTCM tcm => QName -> tcm Bool
isEtaRecord r = do
  def <- theDef <$> getConstInfo r
  return $ case def of
    Record{recEtaEquality = eta} -> eta
    _                            -> False

-- | Check if a name refers to a record constructor.
isRecordConstructor :: MonadTCM tcm => QName -> tcm Bool
isRecordConstructor c = do
  def <- theDef <$> getConstInfo c
  case def of
    Constructor{ conData = r } -> isRecord r
    _                          -> return False

-- | Check if a constructor name is the internally generated record constructor.
isGeneratedRecordConstructor :: MonadTCM tcm => QName -> tcm Bool
isGeneratedRecordConstructor c = do
  def <- theDef <$> getConstInfo c
  case def of
    Constructor{ conData = r } -> do
      def <- theDef <$> getConstInfo r
      case def of
        Record{ recNamedCon = False } -> return True
        _                             -> return False
    _ -> return False

{-| Compute the eta expansion of a record. The first argument should be
    the name of a record type. Given

    @record R : Set where x : A; y : B; .z : C@

    and @r : R@, @etaExpand R [] r@ is @[R.x r, R.y r, DontCare]@
-}
etaExpandRecord :: MonadTCM tcm => QName -> Args -> Term -> tcm (Telescope, Args)
etaExpandRecord r pars u = do
  Record{ recFields = xs, recTel = tel } <- getRecordDef r
  let tel' = apply tel pars
  case u of
    Con _ args -> return (tel', args)  -- Already expanded.
    _          -> do
      -- irrelevant fields are expanded to DontCare
      -- this is sound because etaExpandRecord is only called during conversion
      -- WARNING: do not use etaExpandRecord to expand MetaVars!!
      let proj (Arg h Irrelevant _) = Arg h Irrelevant DontCare
          proj (Arg h rel x)        = Arg h rel $
            Def x $ map hide pars ++ [defaultArg u]
      reportSDoc "tc.record.eta" 20 $ vcat
        [ text "eta expanding" <+> prettyTCM u <+> text ":" <+> prettyTCM r
        , nest 2 $ vcat
          [ text "tel' =" <+> prettyTCM tel'
          , text "args =" <+> prettyTCM (map proj xs)
          ]
        ]
      return (tel', map proj xs)
  where
    hide a = a { argHiding = Hidden }

-- | The fields should be eta contracted already.
etaContractRecord :: MonadTCM tcm => QName -> QName -> Args -> tcm Term
etaContractRecord r c args = do
  Record{ recPars = npars, recFields = xs } <- getRecordDef r
  let check a ax = do
      -- @a@ is the constructor argument, @ax@ the corr. record field name
        -- skip irrelevant record fields by returning DontCare
        case (argRelevance a, unArg a) of
          (Irrelevant, _) -> return $ Just DontCare
          -- if @a@ is the record field name applied to (npars+1) args,
          -- then it passes the check
          (_, Def y args) | unArg ax == y && genericLength args == npars + 1
                         -> return (Just $ unArg $ last args)
          _              -> return Nothing
      fallBack = return (Con c args)
  case compare (length args) (length xs) of
    LT -> fallBack       -- Not fully applied
    GT -> __IMPOSSIBLE__ -- Too many arguments. Impossible.
    EQ -> do
      as <- zipWithM check args xs
      case sequence as of
        Just as -> case filter (DontCare /=) as of
          (a:as) ->
            if all (a ==) as
              then do
                reportSDoc "tc.record.eta" 15 $ vcat
                  [ text "record" <+> prettyTCM (Con c args)
                  , text "is eta-contracted to" <+> prettyTCM a
                  ]
                return a
              else fallBack
          _ -> fallBack -- just DontCares
        _ -> fallBack  -- a Nothing

-- | Is the type a hereditarily singleton record type? May return a
-- blocking metavariable.
--
-- Precondition: The name should refer to a record type, and the
-- arguments should be the parameters to the type.

isSingletonRecord ::
  MonadTCM tcm => QName -> Args -> tcm (Either MetaId Bool)
isSingletonRecord = isSingletonRecord' False

isSingletonRecordModuloRelevance ::
  MonadTCM tcm => QName -> Args -> tcm (Either MetaId Bool)
isSingletonRecordModuloRelevance = isSingletonRecord' True

isSingletonRecord' ::
  MonadTCM tcm => Bool -> QName -> Args -> tcm (Either MetaId Bool)
isSingletonRecord' regardIrrelevance r ps =
  check =<< ((`apply` ps) <$> getRecordFieldTypes r)
  where
  check EmptyTel            = return (Right True)
  check (ExtendTel arg tel) | regardIrrelevance && argRelevance arg == Irrelevant =
    underAbstraction arg tel check
  check (ExtendTel arg tel) = do
    TelV _ t <- telView $ unArg arg
    t <- reduceB $ unEl t
    case t of
      Blocked m _            -> return (Left m)
      NotBlocked (MetaV m _) -> return (Left m)
      NotBlocked (Def r ps)  ->
        ifM (not <$> isRecord r) (return $ Right False) $ do
          isRec <- isSingletonRecord' regardIrrelevance r ps
          case isRec of
            Left _      -> return isRec
            Right False -> return isRec
            Right True  -> underAbstraction arg tel $ check
      _ -> return (Right False)
