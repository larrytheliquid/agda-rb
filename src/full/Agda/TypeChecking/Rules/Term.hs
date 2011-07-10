{-# LANGUAGE CPP, PatternGuards #-}

module Agda.TypeChecking.Rules.Term where

import Control.Applicative
import Control.Arrow ((***), (&&&))
import Control.Monad.Trans
import Control.Monad.Reader
import Control.Monad.Error
import Data.Maybe
import Data.List hiding (sort)
import qualified Agda.Utils.IO.Locale as LocIO
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified Agda.Syntax.Abstract as A
import qualified Agda.Syntax.Abstract.Views as A
import qualified Agda.Syntax.Info as A
import Agda.Syntax.Concrete.Pretty () -- only Pretty instances
import Agda.Syntax.Common
import Agda.Syntax.Fixity
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Generic
import Agda.Syntax.Position
import Agda.Syntax.Literal
import Agda.Syntax.Abstract.Views
import Agda.Syntax.Scope.Base (emptyScopeInfo)
import Agda.Syntax.Translation.InternalToAbstract (reify)

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.MetaVars
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Records
import Agda.TypeChecking.Conversion
import Agda.TypeChecking.Primitive
import Agda.TypeChecking.Constraints
import Agda.TypeChecking.Free
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Datatypes
import Agda.TypeChecking.Irrelevance
import Agda.TypeChecking.EtaContract
import Agda.TypeChecking.Quote
import Agda.TypeChecking.CompiledClause
import Agda.TypeChecking.Level
import {-# SOURCE #-} Agda.TypeChecking.Rules.Builtin.Coinduction

import Agda.Utils.Fresh
import Agda.Utils.Tuple
import Agda.Utils.Permutation

import {-# SOURCE #-} Agda.TypeChecking.Empty (isEmptyTypeC)
import {-# SOURCE #-} Agda.TypeChecking.Rules.Decl (checkSectionApplication)
import {-# SOURCE #-} Agda.TypeChecking.Rules.Def (checkFunDef)

import Agda.Utils.Monad
import Agda.Utils.Size

#include "../../undefined.h"
import Agda.Utils.Impossible

---------------------------------------------------------------------------
-- * Types
---------------------------------------------------------------------------

-- | Check that an expression is a type.
isType :: A.Expr -> Sort -> TCM Type
isType e s =
    traceCall (IsTypeCall e s) $ do
    v <- checkExpr e (sort s)
    return $ El s v

-- | Check that an expression is a type without knowing the sort.
isType_ :: A.Expr -> TCM Type
isType_ e =
    traceCall (IsType_ e) $ do
    s <- workOnTypes $ newSortMeta
    isType e s

leqType_ :: MonadTCM tcm => Type -> Type -> tcm Constraints
leqType_ t t' = workOnTypes $ leqType t t'

{- UNUSED
-- | Force a type to be a Pi. Instantiates if necessary. The 'Hiding' is only
--   used when instantiating a meta variable.

forcePi :: MonadTCM tcm => Hiding -> String -> Type -> tcm (Type, Constraints)
forcePi h name (El s t) =
    do	t' <- reduce t
	case t' of
	    Pi _ _	-> return (El s t', [])
	    Fun _ _	-> return (El s t', [])
            _           -> do
                sa <- newSortMeta
                sb <- newSortMeta
                let s' = sLub sa sb

                a <- newTypeMeta sa
                x <- freshName_ name
		let arg = Arg h Relevant a
                b <- addCtx x arg $ newTypeMeta sb
                let ty = El s' $ Pi arg (Abs (show x) b)
                cs <- equalType (El s t') ty
                ty' <- reduce ty
                return (ty', cs)
-}

---------------------------------------------------------------------------
-- * Telescopes
---------------------------------------------------------------------------

{- UNUSED
-- | Type check a telescope. Binds the variables defined by the telescope.
checkTelescope :: A.Telescope -> Sort -> (Telescope -> TCM a) -> TCM a
checkTelescope [] s ret = ret EmptyTel
checkTelescope (b : tel) s ret =
    checkTypedBindings b s $ \tel1 ->
    checkTelescope tel s   $ \tel2 ->
	ret $ abstract tel1 tel2

-- | Check a typed binding and extends the context with the bound variables.
--   The telescope passed to the continuation is valid in the original context.
checkTypedBindings :: A.TypedBindings -> Sort -> (Telescope -> TCM a) -> TCM a
checkTypedBindings (A.TypedBindings i (Arg h rel b)) s ret =
    checkTypedBinding h rel s b $ \bs ->
    ret $ foldr (\(x,t) -> ExtendTel (Arg h rel t) . Abs x) EmptyTel bs

checkTypedBinding :: Hiding -> Relevance -> Sort -> A.TypedBinding -> ([(String,Type)] -> TCM a) -> TCM a
checkTypedBinding h rel s (A.TBind i xs e) ret = do
    t <- isType e s
    addCtxs xs (Arg h rel t) $ ret $ mkTel xs t
    where
	mkTel [] t     = []
	mkTel (x:xs) t = (show $ nameConcrete x,t) : mkTel xs (raise 1 t)
checkTypedBinding h rel s (A.TNoBind e) ret = do
    t <- isType e s
    ret [("_",t)]
-}

-- | Type check a telescope. Binds the variables defined by the telescope.
checkTelescope_ :: A.Telescope -> (Telescope -> TCM a) -> TCM a
checkTelescope_ [] ret = ret EmptyTel
checkTelescope_ (b : tel) ret =
    checkTypedBindings_ b $ \tel1 ->
    checkTelescope_ tel   $ \tel2 ->
	ret $ abstract tel1 tel2

-- | Check a typed binding and extends the context with the bound variables.
--   The telescope passed to the continuation is valid in the original context.
checkTypedBindings_ :: A.TypedBindings -> (Telescope -> TCM a) -> TCM a
checkTypedBindings_ = checkTypedBindings LOPi

data LamOrPi = LamOP | LOPi deriving (Eq,Show)

-- | Check a typed binding and extends the context with the bound variables.
--   The telescope passed to the continuation is valid in the original context.
--
--   Parametrized by a flag wether we check a typed lambda or a Pi.
--   This flag is needed for irrelevance.
checkTypedBindings :: LamOrPi -> A.TypedBindings -> (Telescope -> TCM a) -> TCM a
checkTypedBindings lamOrPi (A.TypedBindings i (Arg h rel b)) ret =
    checkTypedBinding lamOrPi h rel b $ \bs ->
    ret $ foldr (\(x,t) -> ExtendTel (Arg h rel t) . Abs x) EmptyTel bs

checkTypedBinding :: LamOrPi -> Hiding -> Relevance -> A.TypedBinding -> ([(String,Type)] -> TCM a) -> TCM a
checkTypedBinding lamOrPi h rel (A.TBind i xs e) ret = do
    t <- modEnv lamOrPi $ isType_ e
    -- Andreas, 2011-04-26 irrelevant function arguments may appear
    -- non-strictly in the codomain type
    addCtxs xs (Arg h (modRel lamOrPi rel) t) $ ret $ mkTel xs t
    where
        -- if we are checking a typed lambda, we resurrect before we check the
        -- types, but do not modify the new context entries
        -- otherwise, if we are checking a pi, we do not resurrect, but
        -- modify the new context entries
        modEnv LamOP = workOnTypes
        modEnv LOPi  = id
        modRel LamOP = id
        modRel LOPi  = irrToNonStrict
	mkTel [] t     = []
	mkTel (x:xs) t = (show $ nameConcrete x,t) : mkTel xs (raise 1 t)
checkTypedBinding lamOrPi h rel (A.TNoBind e) ret = do
    t <- isType_ e
    ret [("_",t)]

{- OLD CODE
-- | Check a typed binding and extends the context with the bound variables.
--   The telescope passed to the continuation is valid in the original context.
checkTypedBindings_ :: A.TypedBindings -> (Telescope -> TCM a) -> TCM a
checkTypedBindings_ (A.TypedBindings i (Arg h rel b)) ret =
    checkTypedBinding_ h rel b $ \bs ->
    ret $ foldr (\(x,t) -> ExtendTel (Arg h rel t) . Abs x) EmptyTel bs

checkTypedBinding_ :: Hiding -> Relevance -> A.TypedBinding -> ([(String,Type)] -> TCM a) -> TCM a
checkTypedBinding_ h rel (A.TBind i xs e) ret = do
    t <- isType_ e
    -- Andreas, 2011-04-26 irrelevant function arguments may appear
    -- non-strictly in the codomain type
    addCtxs xs (Arg h (irrToNonStrict rel) t) $ ret $ mkTel xs t
    where
	mkTel [] t     = []
	mkTel (x:xs) t = (show $ nameConcrete x,t) : mkTel xs (raise 1 t)
checkTypedBinding_ h rel (A.TNoBind e) ret = do
    t <- isType_ e
    ret [("_",t)]
-}

---------------------------------------------------------------------------
-- * Literal
---------------------------------------------------------------------------

checkLiteral :: Literal -> Type -> TCM Term
checkLiteral lit t = do
    t' <- litType lit
    v  <- blockTerm t (Lit lit) $ leqType_ t' t
    return v

litType :: Literal -> TCM Type
litType l = case l of
    LitInt _ _	  -> el <$> primNat
    LitFloat _ _  -> el <$> primFloat
    LitChar _ _   -> el <$> primChar
    LitString _ _ -> el <$> primString
    LitQName _ _  -> el <$> primQName
  where
    el t = El (mkType 0) t

---------------------------------------------------------------------------
-- * Terms
---------------------------------------------------------------------------

-- TODO: move somewhere suitable
reduceCon :: MonadTCM tcm => QName -> tcm QName
reduceCon c = do
  Con c [] <- constructorForm =<< reduce (Con c [])
  return c

-- | @checkArguments' exph r args t0 t e k@ tries @checkArguments exph args t0 t@.
-- If it succeeds, it continues @k@ with the returned results.  If it fails,
-- it registers a postponed typechecking problem and returns the resulting new
-- meta variable.
--
-- Checks @e := ((_ : t0) args) : t@.
checkArguments' ::
  ExpandHidden -> Range -> [NamedArg A.Expr] -> Type -> Type -> A.Expr ->
  (Args -> Type -> Constraints -> TCM Term) -> TCM Term
checkArguments' exph r args t0 t e k = do
  z <- runErrorT $ checkArguments exph r args t0 t
  case z of
    Right (vs, t1, cs) -> k vs t1 cs
      -- vs = evaluated args
      -- t1 = remaining type (needs to be subtype of t)
      -- cs = new constraints
    Left t0            -> postponeTypeCheckingProblem e t (unblockedTester t0)
      -- if unsuccessful, postpone checking e : t until t0 unblocks

-- | Type check an expression.
checkExpr :: A.Expr -> Type -> TCM Term
checkExpr e t =
    verboseBracket "tc.term.expr.top" 5 "checkExpr" $
    traceCall (CheckExpr e t) $ localScope $ do
    reportSDoc "tc.term.expr.top" 15 $
        text "Checking" <+> sep
	  [ fsep [ prettyTCM e, text ":", prettyTCM t ]
	  , nest 2 $ text "at " <+> (text . show =<< getCurrentRange)
	  ]
    t <- reduce t
    reportSDoc "tc.term.expr.top" 15 $
        text "    --> " <+> prettyTCM t
    let scopedExpr (A.ScopedExpr scope e) = setScope scope >> scopedExpr e
	scopedExpr e			  = return e

        unScope (A.ScopedExpr scope e) = unScope e
        unScope e                      = e

    e <- scopedExpr e
    case e of

	-- Insert hidden lambda if appropriate
	_   | FunV (Arg h rel _) _ <- funView (unEl t)
            , not (hiddenLambdaOrHole h e)
            , h /= NotHidden                          -> do
		x <- freshName r (argName t)
                reportSLn "tc.term.expr.impl" 15 $ "Inserting implicit lambda"
		checkExpr (A.Lam (A.ExprRange $ getRange e) (A.DomainFree h rel x) e) t
	    where
		r = case rStart $ getRange e of
                      Nothing  -> noRange
                      Just pos -> posToRange pos pos

                hiddenLambdaOrHole h (A.AbsurdLam _ h') | h == h'                      = True
		hiddenLambdaOrHole h (A.Lam _ (A.DomainFree h' _ _) _) | h == h'       = True
		hiddenLambdaOrHole h (A.Lam _ (A.DomainFull (A.TypedBindings _ (Arg h' _ _))) _)
                  | h == h'                                                            = True
		hiddenLambdaOrHole _ (A.QuestionMark _)				       = True
		hiddenLambdaOrHole _ _						       = False

	-- Variable or constant application
           -- Subcase: ambiguous constructor
	_   | Application (HeadCon cs@(_:_:_)) args <- appView e -> do
                -- First we should figure out which constructor we want.
                reportSLn "tc.check.term" 40 $ "Ambiguous constructor: " ++ show cs

                -- Get the datatypes of the various constructors
                let getData Constructor{conData = d} = d
                    getData _                        = __IMPOSSIBLE__
                reportSLn "tc.check.term" 40 $ "  ranges before: " ++ show (getRange cs)
                -- We use the reduced constructor when disambiguating, but
                -- the original constructor for type checking. This is important
                -- since they may have different types (different parameters).
                -- See issue 279.
                cs  <- zip cs . zipWith setRange (map getRange cs) <$> mapM reduceCon cs
                reportSLn "tc.check.term" 40 $ "  ranges after: " ++ show (getRange cs)
                reportSLn "tc.check.term" 40 $ "  reduced: " ++ show cs
                dcs <- mapM (\(c0, c1) -> (getData /\ const c0) . theDef <$> getConstInfo c1) cs

                -- Type error
                let badCon t = typeError $ DoesNotConstructAnElementOf
                                            (fst $ head cs) t

                -- Lets look at the target type at this point
                let getCon = do
                      TelV _ t1 <- telView t
                      t1 <- reduceB $ unEl t1
                      reportSDoc "tc.check.term.con" 40 $ nest 2 $
                        text "target type: " <+> prettyTCM t1
                      case t1 of
                        NotBlocked (Def d _) -> do
                          let dataOrRec = case [ c | (d', c) <- dcs, d == d' ] of
                                c:_ -> do
                                  reportSLn "tc.check.term" 40 $ "  decided on: " ++ show c
                                  return (Just c)
                                []  -> badCon (Def d [])
                          defn <- theDef <$> getConstInfo d
                          case defn of
                            Datatype{} -> dataOrRec
                            Record{}   -> dataOrRec
                            _ -> badCon (ignoreBlocking t1)
                        NotBlocked (MetaV _ _)  -> return Nothing
                        Blocked{} -> return Nothing
                        _ -> badCon (ignoreBlocking t1)
                let unblock = isJust <$> getCon
                mc <- getCon
                case mc of
                  Just c  -> checkConstructorApplication e t c args
                  Nothing -> postponeTypeCheckingProblem e t unblock

              -- Subcase: non-ambiguous constructor
            | Application (HeadCon [c]) args <- appView e ->
                checkConstructorApplication e t c args
              -- Subcase: defined symbol or variable.
            | Application hd args <- appView e ->
                checkHeadApplication e t hd args

	A.WithApp _ e es -> typeError $ NotImplemented "type checking of with application"

        -- check |- Set l : t  (requires universe polymorphism)
        A.App i s (Arg NotHidden r l)
          | A.Set _ 0 <- unScope s ->
          ifM (not <$> hasUniversePolymorphism)
              (typeError $ GenericError "Use --universe-polymorphism to enable level arguments to Set")
          $ do
            lvl <- primLevel
            -- allow NonStrict variables when checking level
            --   Set : (NonStrict) Level -> Set\omega
            n   <- levelView =<< applyRelevanceToContext NonStrict
                                  (checkExpr (namedThing l) (El (mkType 0) lvl))
            -- check that Set (l+1) <= t
            reportSDoc "tc.univ.poly" 10 $
              text "checking Set " <+> prettyTCM n <+>
              text "against" <+> prettyTCM t
            blockTerm t (Sort $ Type n) $ leqType_ (sort $ sSuc $ Type n) t

        A.App i q (Arg NotHidden r e)
          | A.Quote _ <- unScope q -> do
          let quoted (A.Def x) = return x
              quoted (A.Con (AmbQ [x])) = return x
              quoted (A.Con (AmbQ xs))  = typeError $ GenericError $ "quote: Ambigous name: " ++ show xs
              quoted (A.ScopedExpr _ e) = quoted e
              quoted _                  = typeError $ GenericError $ "quote: not a defined name"
          x <- quoted (namedThing e)
          ty <- qNameType
          blockTerm t (quoteName x) $ leqType_ ty t

	  | A.Unquote _ <- unScope q ->
	     do e1 <- checkExpr (namedThing e) =<< el primAgdaTerm
	        e2 <- unquote e1
                checkTerm e2 t
        A.Quote _ -> typeError $ GenericError "quote must be applied to a defined name"
        A.Unquote _ -> typeError $ GenericError "unquote must be applied to a term"

{- Andreas, 2011-05-09 I thought the A.App case below is dead, but it ain't
        -- application is handled in spine fashion (see above, appView)
	A.App i f arg -> __IMPOSSIBLE__
-}
-- NOT DEAD! [ Andreas, 2011-04-28 DEAD CASE, never used, must be stale code]
	A.App i f arg -> do
	    (v0, t0)	 <- inferExpr f
	    checkArguments' ExpandLast (getRange e) [arg] t0 t e $ \vs t1 cs ->
	      blockTerm t (apply v0 vs) $ (cs ++) <$> leqType_ t1 t

        A.AbsurdLam i h -> do
          t <- reduceB =<< instantiateFull t
          case t of
            Blocked{}                 -> postponeTypeCheckingProblem_ e $ ignoreBlocking t
            NotBlocked (El _ MetaV{}) -> postponeTypeCheckingProblem_ e $ ignoreBlocking t
            NotBlocked t' -> case funView $ unEl t' of
              FunV (Arg h' _ a) _
                | h == h' && not (null $ foldTerm metas a) ->
                    postponeTypeCheckingProblem e (ignoreBlocking t) $
                      null . foldTerm metas <$> instantiateFull a
                | h == h' -> do
                  cs' <- isEmptyTypeC a
                  -- Add helper function
                  top <- currentModule
                  let name = "absurd"
                  aux <- qualify top <$> freshName (getRange i) name
                  -- if we are in irrelevant position, the helper function
                  -- is added as irrelevant
                  rel <- asks envRelevance
                  reportSDoc "tc.term.absurd" 10 $ vcat
                    [ text "Adding absurd function" <+> prettyTCM rel <> prettyTCM aux
                    , nest 2 $ text "of type" <+> prettyTCM t'
                    ]
                  addConstant aux $ Defn rel aux t' (defaultDisplayForm aux) 0 noCompiledRep
                                  $ Function
                                    { funClauses        =
                                        [Clause { clauseRange = getRange e
                                                , clauseTel   = EmptyTel
                                                , clausePerm  = Perm 0 []
                                                , clausePats  = [Arg h Relevant $ VarP "()"]
                                                , clauseBody  = NoBody
                                                }
                                        ]
                                    , funCompiled       = Fail
                                    , funDelayed        = NotDelayed
                                    , funInv            = NotInjective
                                    , funAbstr          = ConcreteDef
                                    , funPolarity       = [Covariant]
                                    , funArgOccurrences = [Unused]
                                    , funProjection     = Nothing
                                    }
                  blockTerm t' (Def aux []) $ return cs'
                | otherwise -> typeError $ WrongHidingInLambda t'
              _ -> typeError $ ShouldBePi t'
          where
            metas (MetaV m _) = [m]
            metas _           = []

{- Andreas, 2011-04-27 DOES NOT WORK
   -- a telescope is not for type checking abstract syn

	A.Lam i (A.DomainFull b) e -> do
            -- check the types, get the telescope with unchanged relevance
	    (tel, t1, cs) <- workOnTypes $ checkTypedBindings_ b $ \tel -> do
	       t1 <- newTypeMeta_
               cs <- escapeContext (size tel) $ leqType (telePi tel t1) t
               return (tel, t1, cs)
            -- check the body under the unchanged telescope
            v <- addCtxTel tel $ do teleLam tel <$> checkExpr e t1
	    blockTerm t v (return cs)
-}
	A.Lam i (A.DomainFull b) e -> do
	    (v, cs) <- checkTypedBindings LamOP b $ \tel -> do
                (t1, cs) <- workOnTypes $ do
	          t1 <- newTypeMeta_
                  cs <- escapeContext (size tel) $ leqType (telePi tel t1) t
                  return (t1, cs)
                v <- checkExpr e t1
                return (teleLam tel v, cs)
	    blockTerm t v (return cs)

	A.Lam i (A.DomainFree h rel x) e0 -> do
	    -- (t',cs) <- forcePi h (show x) t
            t <- reduceB t
            case t of
              Blocked{}                 -> postponeTypeCheckingProblem_ e $ ignoreBlocking t
              NotBlocked (El _ MetaV{}) -> postponeTypeCheckingProblem_ e $ ignoreBlocking t
              NotBlocked t' -> case funView $ unEl t' of
		FunV arg0@(Arg h' rel' a) _
                  -- Andreas, 2011-04-07 if lambda has explicit irrelevance
                  --   marker, it needs to coincide with relevance of fun.type
                    | rel == Irrelevant && rel' /= Irrelevant ->
                        typeError $ WrongIrrelevanceInLambda t'
		    | h /= h' ->
			typeError $ WrongHidingInLambda t'
		    | otherwise -> do
			v <- addCtx x arg0 $ do
                              let arg = Arg h rel' (Var 0 [])
                                  tb  = raise 1 t' `piApply` [arg]
                              v <- checkExpr e0 tb
                              return $ Lam h $ Abs (show x) v
			-- blockTerm t v (return cs)
                        return v
		_   -> typeError $ ShouldBePi t'

	A.QuestionMark i ->
          case A.metaNumber i of
            Nothing -> do
              setScope (A.metaScope i)
              newQuestionMark t
            -- Rechecking an existing metavariable
            Just n -> do
              let v = MetaV (MetaId n) []
              HasType _ t' <- mvJudgement <$> lookupMeta (MetaId n)
              blockTerm t v $ leqType t' t
	A.Underscore i   ->
          case A.metaNumber i of
            Nothing -> do
              setScope (A.metaScope i)
              newValueMeta t
            -- Rechecking an existing metavariable
            Just n -> do
              let v = MetaV (MetaId n) []
              HasType _ t' <- mvJudgement <$> lookupMeta (MetaId n)
              blockTerm t v $ leqType t' t

	A.Lit lit    -> checkLiteral lit t
	A.Let i ds e -> checkLetBindings ds $ checkExpr e t
	A.Pi _ tel e -> do
	    t' <- checkTelescope_ tel $ \tel -> do
                    t   <- instantiateFull =<< isType_ e
                    tel <- instantiateFull tel
                    return $ telePi_ tel t
            let s = getSort t'
            when (s == Inf) $ reportSDoc "tc.term.sort" 20 $
              vcat [ text ("reduced to omega:")
                   , nest 2 $ text "t   =" <+> prettyTCM t'
                   , nest 2 $ text "cxt =" <+> (prettyTCM =<< getContextTelescope)
                   ]
	    blockTerm t (unEl t') $ leqType_ (sort s) t
	A.Fun _ (Arg h r a) b -> do
	    a' <- isType_ a
	    b' <- isType_ b
	    s <- reduce $ getSort a' `sLub` getSort b'
	    blockTerm t (Fun (Arg h r a') b') $ leqType_ (sort s) t
	A.Set _ n    -> do
          n <- ifM typeInType (return 0) (return n)
	  blockTerm t (Sort (mkType n)) $ leqType_ (sort $ mkType $ n + 1) t
	A.Prop _     -> do
          typeError $ GenericError "Prop is no longer supported"
          -- s <- ifM typeInType (return $ mkType 0) (return Prop)
	  -- blockTerm t (Sort Prop) $ leqType_ (sort $ mkType 1) t

	A.Rec _ fs  -> do
	  t <- reduce t
	  case unEl t of
	    Def r vs  -> do
	      axs    <- getRecordFieldNames r
              let xs = map unArg axs
	      ftel   <- getRecordFieldTypes r
              con    <- getRecordConstructor r
              scope  <- getScope
              let meta = A.Underscore $ A.MetaInfo (getRange e) scope Nothing
	      es   <- orderFields r meta xs fs
	      let tel = ftel `apply` vs
	      (args, cs) <- checkArguments_ ExpandLast (getRange e)
			      (zipWith (\ax e -> fmap (const (unnamed e)) ax) axs es)
                              tel
	      blockTerm t (Con con args) $ return cs
            MetaV _ _ -> do
              reportSDoc "tc.term.expr.rec" 10 $ sep
                [ text "Postponing type checking of"
                , nest 2 $ prettyA e <+> text ":" <+> prettyTCM t
                ]
              postponeTypeCheckingProblem_ e t
	    _         -> typeError $ ShouldBeRecordType t

	A.Var _    -> __IMPOSSIBLE__
	A.Def _    -> __IMPOSSIBLE__
	A.Con _    -> __IMPOSSIBLE__

        A.ETel _   -> __IMPOSSIBLE__

	A.DontCare -> -- can happen in the context of with functions
                      return DontCare
                      -- __IMPOSSIBLE__

	A.ScopedExpr scope e -> setScope scope >> checkExpr e t

        e0@(A.QuoteGoal _ x e) -> do
          t' <- etaContract =<< normalise t
          let metas = foldTerm (\v -> case v of
                                       MetaV m _ -> [m]
                                       _         -> []
                               ) t'
          case metas of
            _:_ -> postponeTypeCheckingProblem e0 t' $ and <$> mapM isInstantiatedMeta metas
            []  -> do
              quoted <- quoteTerm (unEl t')
              tmType <- agdaTermType
              (v,ty) <- addLetBinding Relevant x quoted tmType (inferExpr e)
              blockTerm t' v $ leqType_ ty t'

-- | Infer the type of a head thing (variable, function symbol, or constructor)
inferHead :: Head -> TCM (Args -> Term, Type)
inferHead (HeadVar x) = do -- traceCall (InferVar x) $ do
  (u, a) <- getVarInfo x
  when (unusableRelevance $ argRelevance a) $
    typeError $ VariableIsIrrelevant x
  return (apply u, unArg a)
inferHead (HeadDef x) = do
  (u, a) <- inferDef Def x
  return (apply u, a)
inferHead (HeadCon [c]) = do

  -- Constructors are polymorphic internally so when building the constructor
  -- term we should throw away arguments corresponding to parameters.

  -- First, inferDef will try to apply the constructor to the free parameters
  -- of the current context. We ignore that.
  (u, a) <- inferDef (\c _ -> Con c []) c

  -- Next get the number of parameters in the current context.
  Constructor{conPars = n} <- theDef <$> (instantiateDef =<< getConstInfo c)

  verboseS "tc.term.con" 7 $ do
    liftIO $ LocIO.putStrLn $ unwords [show c, "has", show n, "parameters."]

  -- So when applying the constructor throw away the parameters.
  return (apply u . genericDrop n, a)
inferHead (HeadCon _) = __IMPOSSIBLE__  -- inferHead will only be called on unambiguous constructors

inferDef :: (QName -> Args -> Term) -> QName -> TCM (Term, Type)
inferDef mkTerm x =
    traceCall (InferDef (getRange x) x) $ do
    d  <- instantiateDef =<< getConstInfo x
    -- irrelevant defs are only allowed in irrelevant position
    let drel = defRelevance d
    when (drel /= Relevant) $ do
      rel <- asks envRelevance
      reportSDoc "tc.irr" 50 $ vcat
        [ text "declaration relevance =" <+> text (show drel)
        , text "context     relevance =" <+> text (show rel)
        ]
      unless (drel `moreRelevant` rel) $ typeError $ DefinitionIsIrrelevant x
    vs <- freeVarsToApply x
    verboseS "tc.term.def" 10 $ do
      ds <- mapM prettyTCM vs
      dx <- prettyTCM x
      dt <- prettyTCM $ defType d
      liftIO $ LocIO.putStrLn $ "inferred def " ++ unwords (show dx : map show ds) ++ " : " ++ show dt
    return (mkTerm x vs, defType d)

-- | Check the type of a constructor application. This is easier than
--   a general application since the implicit arguments can be inserted
--   without looking at the arguments to the constructor.
checkConstructorApplication :: A.Expr -> Type -> QName -> [NamedArg A.Expr] -> TCM Term
checkConstructorApplication org t c args = do
  checkHead t args
{-
  TelV gamma d <- telView t

  -- Eta expand the constructor applications so it's fully applied
  let realName "_" = "carg"
      realName  x  = x
      gamma' = telToList gamma

    -- Generate fresh names for eta expansion variables
  vars <- sequence [ Arg h <$> freshName_ (realName x)
                   | Arg h (x, _) <- gamma' ]

    -- Compute the context of the variables
  let cxt = [ (unArg x, fmap snd t) | (x, t) <- zip vars gamma' ]
      extendCxt cxt m = foldr (uncurry addCtx) m cxt
      etaExpansion t = foldr lam t gamma'
        where lam (Arg h (x, _)) t = Lam h (Abs x t)

  -- Go inside the lambdas generated by the expansion
  extendCxt cxt $ do

  -- Make sure to shadow some things we shouldn't use
  t        <- return d
  args     <- return $ args ++ map (fmap (unnamed . A.Var)) vars
  fallback <- return $ etaExpansion <$> checkHead t args

  -- Make sure we're checking against the right datatype
  d   <- getConstructorData c
  mdi <- getDatatypeInfo t
  case mdi of
    Nothing -> fallback
    Just dinfo@DataInfo{ datatypeName   = d'
                       , datatypeParTel = parTel
                       , datatypePars   = dpars
                       , datatypeIxTel  = ixTel
                       , datatypeIxs    = indices
                       }
      | d /= d'   -> fallback
      | otherwise -> do

      -- Split the given arguments into explicitly given parameters and normal
      -- arguments
      (pars, args) <- return $ splitArgs (map (fst . unArg) $ telToList parTel)
                                         args

      reportSDoc "tc.term.con" 30 $ vcat
        [ text "checking constructor application"
        , nest 2 $ vcat
          [ text "c      =" <+> prettyTCM c
          , text "A.pars =" <+> prettyList (map prettyA pars)
          , text "A.args =" <+> prettyList (map prettyA args)
          , text "ptel   =" <+> prettyTCM parTel
          , text "itel   =" <+> addCtxTel parTel (prettyTCM ixTel)
          , text "pars   =" <+> prettyTCM dpars
          , text "ixs    =" <+> prettyTCM indices
          ]
        ]

      -- Check the parameters. Just means checking that any given
      -- parameters are equal to the expected parameters.
      -- checkParams pars parTel $ do

      fallback

  -- Plan
  --  * Check the parameters
  --    + if they're present type check and compare to the parameters to the
  --      datatype, otherwise just continue
  --  * Insert implicit constructor arguments (not counting parameters)
  --  * Check the arguments
  --  * Compare the computed indices from the constructor with the given
  --    indices
-}
  where
    checkHead t args = checkHeadApplication org t (HeadCon [c]) args

    -- Split the arguments to a constructor into those corresponding
    -- to parameters and those that don't. Dummy underscores are inserted
    -- for parameters that are not given explicitly.
    splitArgs [] args = ([], args)
    splitArgs ps []   =
          (map (const dummyUnderscore) ps, args)
    splitArgs ps args@(Arg NotHidden _ _ : _) =
          (map (const dummyUnderscore) ps, args)
    splitArgs (p:ps) (arg : args)
      | elem mname [Nothing, Just p] =
          (arg :) *** id $ splitArgs ps args
      | otherwise =
          (dummyUnderscore :) *** id $ splitArgs ps (arg:args)
      where
        mname = nameOf (unArg arg)

    dummyUnderscore = Arg Hidden Relevant (unnamed $ A.Underscore $ A.MetaInfo noRange emptyScopeInfo Nothing)

--   TelV _ (El _ (Def d dargs)) <- telView t
--   condef  <- getConstInfo c
--   let pars = map unArg $ genericTake (conPars $ theDef condef) dargs
--   (_, contype) <- inferHead (HeadCon [c])
--   TelV contel _ <- telView contype
--   let args' = insertParams contel pars args
--   reportSDoc "tc.term.con" 10 $ vcat
--     [ text "Checking constructor application"
--     , nest 2 $ vcat
--       [ text "args  =" <+> prettyList (map prettyA args)
--       , text "args' =" <+> prettyList (map prettyA args')
--       ]
--     ]
--   checkHeadApplication org t (HeadCon [c]) args'
--   where
--     insertParams :: Telescope -> [Term] -> [NamedArg A.Expr] -> [NamedArg A.Expr]
--     insertParams _ [] args = args
--     insertParams (ExtendTel a tel) (p:ps) (arg:args)
--       | argHiding arg == NotHidden ||
--         notElem argname [Nothing, telname] =
--           Arg Hidden (unnamed $ A.TypeChecked p) :
--           insertParams (absBody tel) ps (arg:args)
--       | otherwise =
--           arg : insertParams (absBody tel) ps args
--       where
--         argname = nameOf (unArg arg)
--         telname = Just (absName tel)
--     insertParams (ExtendTel a tel) (p:ps) [] =
--           Arg Hidden (unnamed $ A.TypeChecked p) :
--           insertParams (absBody tel) ps []
--     insertParams EmptyTel (_:_) _ = __IMPOSSIBLE__

-- | @checkHeadApplication e t hd args@ checks that @e@ has type @t@,
-- assuming that @e@ has the form @hd args@. The corresponding
-- type-checked term is returned.
--
-- If the head term @hd@ is a coinductive constructor, then a
-- top-level definition @fresh tel = hd args@ (where the clause is
-- delayed) is added, where @tel@ corresponds to the current
-- telescope. The returned term is @fresh tel@.
--
-- Precondition: The head @hd@ has to be unambiguous, and there should
-- not be any need to insert hidden lambdas.
checkHeadApplication :: A.Expr -> Type -> A.Head -> [NamedArg A.Expr] -> TCM Term
checkHeadApplication e t hd args = do
  replacing <- envReplace <$> ask
  kit       <- coinductionKit
  if not replacing
   then local (\e -> e { envReplace = True }) defaultResult
   else case hd of
    HeadCon [c] -> do
      (f, t0) <- inferHead hd
      reportSDoc "tc.term.con" 5 $ vcat
        [ text "checkHeadApplication inferred" <+>
          prettyTCM c <+> text ":" <+> prettyTCM t0
        ]
      checkArguments' ExpandLast (getRange hd) args t0 t e $ \vs t1 cs -> do
        TelV eTel eType <- telView t
        -- If the expected type @eType@ is a metavariable we have to make
        -- sure it's instantiated to the proper pi type
        TelV fTel fType <- telViewUpTo (size eTel) t1
        blockTerm t (f vs) $ (cs ++) <$> do
          -- We know that the target type of the constructor (fType)
          -- does not depend on fTel so we can compare fType and eType
          -- first.

          when (size eTel > size fTel) $
            typeError $ UnequalTypes CmpLeq t1 t -- switch because of contravariance
            -- Andreas, 2011-05-10 report error about types rather  telescopes
            -- compareTel CmpLeq eTel fTel >> return () -- This will fail!

          reportSDoc "tc.term.con" 10 $ vcat
            [ text "checking" <+>
              prettyTCM fType <+> text "?<=" <+> prettyTCM eType
            ]
          workOnTypes $ do
            cs1 <- addCtxTel eTel $ leqType fType eType

            cs2 <- compareTel t t1 CmpLeq eTel fTel
            return $ cs1 ++ cs2

    HeadDef c | Just c == (nameOfSharp <$> kit) -> do
      -- TODO: Handle coinductive constructors under lets.
      lets <- envLetBindings <$> ask
      unless (Map.null lets) $
        typeError $ NotImplemented
          "coinductive constructor in the scope of a let-bound variable"

      -- The name of the fresh function.
      i <- fresh :: TCM Integer
      let name = filter (/= '_') (show $ A.qnameName c) ++ "-" ++ show i
      c' <- liftM2 qualify currentModule (freshName_ name)

      -- The application of the fresh function to the relevant
      -- arguments.
      e' <- Def c' <$> getContextArgs

      -- Add the type signature of the fresh function to the
      -- signature.
      i   <- currentMutualBlock
      tel <- getContextTelescope
      -- If we are in irrelevant position, add definition irrelevantly.
      -- TODO: is this sufficient?
      rel <- asks envRelevance
      addConstant c' (Defn rel c' t (defaultDisplayForm c') i noCompiledRep $ Axiom)

      -- Define and type check the fresh function.
      ctx <- getContext
      let info   = A.mkDefInfo (A.nameConcrete $ A.qnameName c') defaultFixity'
                               PublicAccess ConcreteDef noRange
          pats   = map (fmap $ \(n, _) -> Named Nothing (A.VarP n)) $
                       reverse ctx
          clause = A.Clause (A.LHS (A.LHSRange noRange) c' pats [])
                            (A.RHS $ unAppView (A.Application hd args))
                            []

      reportSDoc "tc.term.expr.coind" 15 $ vcat $
          [ text "The coinductive constructor application"
          , nest 2 $ prettyTCM e
          , text "was translated into the application"
          , nest 2 $ prettyTCM e'
          , text "and the function"
          , nest 2 $ prettyTCM rel <> prettyTCM c' <+> text ":"
          , nest 4 $ prettyTCM (telePi tel t)
          , nest 2 $ prettyA clause <> text "."
          ]

      local (\e -> e { envReplace = False }) $
        escapeContext (size ctx) $ checkFunDef Delayed info c' [clause]

      reportSDoc "tc.term.expr.coind" 15 $ do
        def <- theDef <$> getConstInfo c'
        text "The definition is" <+> text (show $ funDelayed def) <>
          text "."

      return e'
    HeadCon _  -> __IMPOSSIBLE__
    HeadVar {} -> defaultResult
    HeadDef {} -> defaultResult
  where
  defaultResult = do
    (f, t0) <- inferHead hd
    checkArguments' ExpandLast (getRange hd) args t0 t e $ \vs t1 cs ->
      blockTerm t (f vs) $ (cs ++) <$> leqType_ t1 t

data ExpandHidden = ExpandLast | DontExpandLast

instance Error Type where
  strMsg _ = __IMPOSSIBLE__
  noMsg = __IMPOSSIBLE__

traceCallE :: Error e => (Maybe r -> Call) -> ErrorT e TCM r -> ErrorT e TCM r
traceCallE call m = do
  z <- lift $ traceCall call' $ runErrorT m
  case z of
    Right e  -> return e
    Left err -> throwError err
  where
    call' Nothing          = call Nothing
    call' (Just (Left _))  = call Nothing
    call' (Just (Right x)) = call (Just x)

-- | Check a list of arguments: @checkArgs args t0 t1@ checks that
--   @t0 = Delta -> t0'@ and @args : Delta@. Inserts hidden arguments to
--   make this happen.  Returns the evaluated arguments @vs@, the remaining
--   type @t0'@ (which should be a subtype of @t1@) and any constraints @cs@
--   that have to be solved for everything to be well-formed.
--
--   TODO: doesn't do proper blocking of terms
checkArguments :: ExpandHidden -> Range -> [NamedArg A.Expr] -> Type -> Type ->
                  ErrorT Type TCM (Args, Type, Constraints)
checkArguments DontExpandLast _ [] t0 t1 = return ([], t0, [])
checkArguments exh r [] t0 t1 =
    traceCallE (CheckArguments r [] t0 t1) $ do
	t0' <- lift $ reduce t0
	t1' <- lift $ reduce t1
	case funView $ unEl t0' of
	    FunV (Arg Hidden rel a) _ | notHPi Hidden $ unEl t1'  -> do
		v  <- lift $ applyRelevanceToContext rel $ newValueMeta a
		let arg = Arg Hidden rel v
		(vs, t0'',cs) <- checkArguments exh r [] (piApply t0' [arg]) t1'
		return (arg : vs, t0'',cs)
	    FunV (Arg Instance rel a) _ | notHPi Instance $ unEl t1'  -> do
                reportSLn "tc.term.args.ifs" 15 $ "inserting implicit meta for type " ++ show a
		(v, c) <- lift $ applyRelevanceToContext rel $ newIFSMeta a
		let arg = Arg Instance rel v
		(vs, t0'',cs) <- checkArguments exh r [] (piApply t0' [arg]) t1'
		return (arg : vs, t0'', (c : cs))
	    _ -> return ([], t0', [])
    where
	notHPi h (Pi  (Arg h' _ _) _) | h == h' = False
	notHPi h (Fun (Arg h' _ _) _) | h == h' = False
	notHPi _ _		        = True

checkArguments exh r args0@(Arg h _ e : args) t0 t1 =
    traceCallE (CheckArguments r args0 t0 t1) $ do
      t0b <- lift $ reduceB t0
      case t0b of
        Blocked{}                 -> throwError $ ignoreBlocking t0b
        NotBlocked (El _ MetaV{}) -> throwError $ ignoreBlocking t0b
        NotBlocked t0' -> do
          -- (t0', cs) <- forcePi h (name e) t0
          e' <- return $ namedThing e
          case (funView $ unEl t0') of
              (FunV (Arg h' rel a) _) |
                h == h' && (h == NotHidden || sameName (nameOf e) (nameInPi $ unEl t0')) -> do
                  u  <- lift $ applyRelevanceToContext rel $ checkExpr e' a
                  let arg = Arg h rel u  -- save relevance info in argument
                  (us, t0'', cs') <- checkArguments exh (fuseRange r e) args (piApply t0' [arg]) t1
                  return (nukeIfIrrelevant arg : us, t0'', cs')
                         where nukeIfIrrelevant arg =
                                 if argRelevance arg == Irrelevant then
                                   arg { unArg = DontCare }
                                  else arg
              (FunV (Arg Instance rel a) _) -> insertIFSUnderscore rel a
              (FunV (Arg Hidden rel a) _) -> insertUnderscore rel
              (FunV (Arg NotHidden _ _) _) -> lift $ typeError $ WrongHidingInApplication t0'
              _ -> lift $ typeError $ ShouldBePi t0'
    where
	insertIFSUnderscore rel a = do (v, c) <- lift $ applyRelevanceToContext rel $ newIFSMeta a
                                       reportSLn "tc.term.args.ifs" 15 $ "inserting implicit meta (2) for type " ++ show a
                                       let arg = Arg Instance rel v
                                       (vs, t0'', cs) <- checkArguments exh r args0 (piApply t0 [arg]) t1
                                       return (arg : vs, t0'', c : cs)
	insertUnderscore rel = do
	  scope <- lift $ getScope
	  let m = A.Underscore $ A.MetaInfo
		  { A.metaRange  = r
		  , A.metaScope  = scope
		  , A.metaNumber = Nothing
		  }
	  checkArguments exh r (Arg Hidden rel (unnamed m) : args0) t0 t1

	name (Named _ (A.Var x)) = show x
	name (Named (Just x) _)    = x
	name _			   = "x"

	sameName Nothing _  = True
	sameName n1	 n2 = n1 == n2

	nameInPi (Pi _ b)  = Just $ absName b
	nameInPi (Fun _ _) = Nothing
	nameInPi _	   = __IMPOSSIBLE__


-- | Check that a list of arguments fits a telescope.
checkArguments_ :: ExpandHidden -> Range -> [NamedArg A.Expr] -> Telescope -> TCM (Args, Constraints)
checkArguments_ exh r args tel = do
    z <- runErrorT $ checkArguments exh r args (telePi tel $ sort Prop) (sort Prop)
    case z of
      Right (args, _, cs) -> return (args, cs)
      Left _              -> __IMPOSSIBLE__


-- | Infer the type of an expression. Implemented by checking against a meta
--   variable.
inferExpr :: A.Expr -> TCM (Term, Type)
inferExpr e = do
    -- Andreas, 2011-04-27
    t <- workOnTypes $ newTypeMeta_
    v <- checkExpr e t
    return (v,t)

checkTerm :: Term -> Type -> TCM Term
checkTerm tm ty = do atm <- reify tm
                     checkExpr atm ty

---------------------------------------------------------------------------
-- * Let bindings
---------------------------------------------------------------------------

checkLetBindings :: [A.LetBinding] -> TCM a -> TCM a
checkLetBindings = foldr (.) id . map checkLetBinding

checkLetBinding :: A.LetBinding -> TCM a -> TCM a
checkLetBinding b@(A.LetBind i rel x t e) ret =
  traceCallCPS_ (CheckLetBinding b) ret $ \ret -> do
    t <- isType_ t
    v <- applyRelevanceToContext rel $ checkExpr e t
    addLetBinding rel x v t ret
checkLetBinding (A.LetApply i x modapp rd rm) ret = do
  -- Any variables in the context that doesn't belong to the current
  -- module should go with the new module.
  -- fv   <- getDefFreeVars =<< (qnameFromList . mnameToList) <$> currentModule
  fv   <- getModuleFreeVars =<< currentModule
  n    <- size <$> getContext
  let new = n - fv
  reportSLn "tc.term.let.apply" 10 $ "Applying " ++ show modapp ++ " with " ++ show new ++ " free variables"
  reportSDoc "tc.term.let.apply" 20 $ vcat
    [ text "context =" <+> (prettyTCM =<< getContextTelescope)
    , text "module  =" <+> (prettyTCM =<< currentModule)
    , text "fv      =" <+> (text $ show fv)
    ]
  checkSectionApplication i x modapp rd rm
  withAnonymousModule x new ret
-- LetOpen is only used for highlighting and has no semantics
checkLetBinding A.LetOpen{} ret = ret
