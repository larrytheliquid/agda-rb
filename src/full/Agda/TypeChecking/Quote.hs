{-# LANGUAGE CPP #-}

module Agda.TypeChecking.Quote where

import Control.Applicative

import Agda.Syntax.Position
import Agda.Syntax.Literal
import Agda.Syntax.Internal
import Agda.Syntax.Common

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Substitute

#include "../undefined.h"
import Agda.Utils.Impossible

quotingKit :: MonadTCM tcm => tcm ((Term -> Term), (Type -> Term))
quotingKit = do
  hidden <- primHidden
  instanceH <- primInstance
  visible <- primVisible
  relevant <- primRelevant
  irrelevant <- primIrrelevant
  nonStrict <- primNonStrict
  forced <- primForced
  nil <- primNil
  cons <- primCons
  arg <- primArgArg
  var <- primAgdaTermVar
  lam <- primAgdaTermLam
  def <- primAgdaTermDef
  con <- primAgdaTermCon
  pi <- primAgdaTermPi
  sort <- primAgdaTermSort
  set <- primAgdaSortSet
  setLit <- primAgdaSortLit
  unsupportedSort <- primAgdaSortUnsupported
  sucLevel <- primLevelSuc
  lub <- primLevelMax
  el <- primAgdaTypeEl
  Con z _ <- primZero
  Con s _ <- primSuc
  unsupported <- primAgdaTermUnsupported
  let t @@ u = apply t [defaultArg u]
      quoteHiding Hidden    = hidden
      quoteHiding Instance  = instanceH
      quoteHiding NotHidden = visible
      quoteRelevance Relevant   = relevant
      quoteRelevance Irrelevant = irrelevant
      quoteRelevance NonStrict  = nonStrict
      quoteRelevance Forced     = forced
      quoteLit (LitInt   _ n)   = iterate suc zero !! fromIntegral n
      quoteLit _                = unsupported
      -- We keep no ranges in the quoted term, so the equality on terms
      -- is only on the structure.
      quoteSortLevelTerm (Max [])              = setLit @@ Lit (LitInt noRange 0)
      quoteSortLevelTerm (Max [ClosedLevel n]) = setLit @@ Lit (LitInt noRange n)
      quoteSortLevelTerm (Max [Plus 0 (NeutralLevel v)]) = set @@ quote v
      quoteSortLevelTerm _                     = unsupported
      quoteSort (Type t)    = quoteSortLevelTerm t
      quoteSort Prop        = unsupportedSort
      quoteSort Inf         = unsupportedSort
      quoteSort DLub{}      = unsupportedSort
      quoteType (El s t) = el @@ quoteSort s @@ quote t
      list [] = nil
      list (a : as) = cons @@ a @@ list as
      zero = con @@ quoteName z @@ nil
      suc n = con @@ quoteName s @@ list [n]
      quoteArg q (Arg h r t) = arg @@ quoteHiding h @@ quoteRelevance r @@ q t
      quoteArgs ts = list (map (quoteArg quote) ts)
      quote (Var n ts) = var @@ Lit (LitInt noRange n) @@ quoteArgs ts
      quote (Lam h t) = lam @@ quoteHiding h @@ quote (absBody t)
      quote (Def x ts) = def @@ quoteName x @@ quoteArgs ts
      quote (Con x ts) = con @@ quoteName x @@ quoteArgs ts
      quote (Pi t u) = pi @@ quoteArg quoteType t
                          @@ quoteType (absBody u)
      quote (Fun t u) = pi @@ quoteArg quoteType t
                           @@ quoteType (raise 1 u) -- do we want a raiseFrom here?
      quote (Level _) = unsupported
      quote (Lit lit) = quoteLit lit
      quote (Sort s)  = sort @@ quoteSort s
      quote MetaV{}   = unsupported
      quote DontCare  = unsupported -- could be exposed at some point but we have to take care
  return (quote, quoteType)

quoteName :: QName -> Term
quoteName x = Lit (LitQName noRange x)

quoteTerm :: MonadTCM tcm => Term -> tcm Term
quoteTerm v = ($v) . fst <$> quotingKit

quoteType :: MonadTCM tcm => Type -> tcm Term
quoteType v = ($v) . snd <$> quotingKit

agdaTermType :: MonadTCM tcm => tcm Type
agdaTermType = El (mkType 0) <$> primAgdaTerm

qNameType :: MonadTCM tcm => tcm Type
qNameType = El (mkType 0) <$> primQName

isCon :: QName -> TCM Term -> TCM Bool
isCon con tm = do t <- tm
                  case t of
                    Con con' _ -> return (con == con')
                    _ -> return False

unquoteFailedGeneric :: String -> TCM a
unquoteFailedGeneric msg = typeError . GenericError $ "Unable to unquote the " ++ msg

unquoteFailed :: String -> String -> Term -> TCM a
unquoteFailed kind msg t = do doc <- prettyTCM t
                              unquoteFailedGeneric $ "term (" ++ show doc ++ ") of type " ++ kind ++ ".\nReason: " ++ msg ++ "."

class Unquote a where
  unquote :: Term -> TCM a

unquoteH :: Unquote a => Arg Term -> TCM a
unquoteH (Arg Hidden Relevant x) = unquote x
unquoteH _                       = unquoteFailedGeneric "argument. It should be `hidden'."

unquoteN :: Unquote a => Arg Term -> TCM a
unquoteN (Arg NotHidden Relevant x) = unquote x
unquoteN _                          = unquoteFailedGeneric "argument. It should be `visible'"

choice :: Monad m => [(m Bool, m a)] -> m a -> m a
choice [] dflt = dflt
choice ((mb, mx) : mxs) dflt = do b <- mb
                                  if b then mx else choice mxs dflt

instance Unquote a => Unquote (Arg a) where
  unquote t = do
    t <- reduce t
    case t of
      Con c [hid,rel,x] -> do
        choice
          [(c `isCon` primArgArg, Arg <$> unquoteN hid <*> unquoteN rel <*> unquoteN x)]
          (unquoteFailed "Arg" "arity 3 and not the `arg' constructor" t)
      _ -> unquoteFailed "Arg" "not of arity 3" t

instance Unquote Integer where
  unquote t = do
    t <- reduce t
    case t of
      Lit (LitInt _ n) -> return n
      _ -> unquoteFailed "Integer" "not a literal integer" t

instance Unquote a => Unquote [a] where
  unquote t = do
    t <- reduce t
    case t of
      Con c [x,xs] -> do
        choice
          [(c `isCon` primCons, (:) <$> unquoteN x <*> unquoteN xs)]
          (unquoteFailed "List" "arity 2 and not the `∷' constructor" t)
      Con c [] -> do
        choice
          [(c `isCon` primNil, return [])]
          (unquoteFailed "List" "arity 0 and not the `[]' constructor" t)
      _ -> unquoteFailed "List" "neither `[]' nor `∷'" t

instance Unquote Hiding where
  unquote t = do
    t <- reduce t
    case t of
      Con c [] -> do
        choice
          [(c `isCon` primHidden,  return Hidden)
          ,(c `isCon` primInstance, return Instance)
          ,(c `isCon` primVisible, return NotHidden)]
          (unquoteFailed "Hiding" "neither `hidden' nor `visible'" t)
      _ -> unquoteFailed "Hiding" "arity is not 0" t

instance Unquote Relevance where
  unquote t = do
    t <- reduce t
    case t of
      Con c [] -> do
        choice
          [(c `isCon` primRelevant,   return Relevant)
          ,(c `isCon` primIrrelevant, return Irrelevant)
          ,(c `isCon` primNonStrict,  return NonStrict)]
          (unquoteFailed "Relevance" "neither `relevant', `irrelevant' nor `nonStrict'" t)
      _ -> unquoteFailed "Relevance" "arity is not 0" t

instance Unquote QName where
  unquote t = do
    t <- reduce t
    case t of
      Lit (LitQName _ x) -> return x
      _                  -> unquoteFailed "QName" "not a literal qname value" t

instance Unquote a => Unquote (Abs a) where
  unquote t = do x <- freshNoName_
                 Abs (show x) <$> unquote t

instance Unquote Sort where
  unquote t = do
    t <- reduce t
    case t of
      Con c [] -> do
        choice
          [(c `isCon` primAgdaSortUnsupported, unquoteFailed "Sort" "unsupported sort" t)]
          (unquoteFailed "Sort" "arity 0 and not the `unsupported' constructor" t)
      Con c [u] -> do
        choice
          [(c `isCon` primAgdaSortSet, Type <$> unquoteN u)
          ,(c `isCon` primAgdaSortLit, Type . levelMax . (:[]) . ClosedLevel <$> unquoteN u)]
          (unquoteFailed "Sort" "arity 1 and not the `set' or the `lit' constructors" t)
      _ -> unquoteFailed "Sort" "not of arity 0 nor 1" t

instance Unquote Level where
  unquote l = Max . (:[]) . Plus 0 . UnreducedLevel <$> unquote l

instance Unquote Type where
  unquote t = do
    t <- reduce t
    case t of
      Con c [s, u] -> do
        choice
          [(c `isCon` primAgdaTypeEl, El <$> unquoteN s <*> unquoteN u)]
          (unquoteFailed "Type" "arity 2 and not the `el' constructor" t)
      _ -> unquoteFailed "Type" "not of arity 2" t

instance Unquote Term where
  unquote t = do
    t <- reduce t
    case t of
      Con c [] ->
        choice
          [(c `isCon` primAgdaTermUnsupported, unquoteFailed "Term" "unsupported term" t)]
          (unquoteFailed "Term" "arity 0 and not the `unsupported' constructor" t)

      Con c [x] -> do
        choice
          [(c `isCon` primAgdaTermSort, Sort <$> unquoteN x)]
          (unquoteFailed "Term" "arity 1 and not the `sort' constructor" t)

      Con c [x,y] ->
        choice
          [(c `isCon` primAgdaTermVar, Var <$> unquoteN x <*> unquoteN y)
          ,(c `isCon` primAgdaTermCon, Con <$> unquoteN x <*> unquoteN y)
          ,(c `isCon` primAgdaTermDef, Def <$> unquoteN x <*> unquoteN y)
          ,(c `isCon` primAgdaTermLam, Lam <$> unquoteN x <*> unquoteN y)
          ,(c `isCon` primAgdaTermPi,  Pi  <$> unquoteN x <*> unquoteN y)]
          (unquoteFailed "Term" "arity 2 and none of Var, Con, Def, Lam, Pi" t)

      Con{} -> unquoteFailed "Term" "neither arity 0 nor 1 nor 2" t
      Lit{} -> unquoteFailed "Term" "unexpected literal" t
      _ -> unquoteFailed "Term" "not a constructor" t
