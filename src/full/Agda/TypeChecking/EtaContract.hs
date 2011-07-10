{-# LANGUAGE CPP #-}

-- | Compute eta short normal forms.
module Agda.TypeChecking.EtaContract where

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Generic
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Free
import Agda.TypeChecking.Monad
import {-# SOURCE #-} Agda.TypeChecking.Records
import {-# SOURCE #-} Agda.TypeChecking.Datatypes
import Agda.Utils.Monad

#include "../undefined.h"
import Agda.Utils.Impossible

-- TODO: move to Agda.Syntax.Internal.SomeThing
data BinAppView = App Term (Arg Term)
                | NoApp Term

binAppView :: Term -> BinAppView
binAppView t = case t of
  Var i xs   -> app (Var i) xs
  Def c xs   -> app (Def c) xs
  Con c xs   -> app (Con c) xs
  Lit _      -> noApp
  Level _    -> noApp   -- could be an application, but let's not eta contract levels
  Lam _ _    -> noApp
  Pi _ _     -> noApp
  Fun _ _    -> noApp
  Sort _     -> noApp
  MetaV _ _  -> noApp
  DontCare   -> noApp
  where
    noApp = NoApp t
    app f [] = noApp
    app f xs = App (f $ init xs) (last xs)

etaContract :: (MonadTCM tcm, TermLike a) => a -> tcm a
etaContract = traverseTermM etaOnce
  where

etaOnce :: (MonadTCM tcm) => Term -> tcm Term
etaOnce v = ignoreAbstractMode $ eta v
  where
    eta t@(Lam h b) = do
      imp <- shouldEtaContractImplicit
      case binAppView (absBody b) of
        App u (Arg h' r v)
          | isVar0 v && allowed imp h' && not (freeIn 0 u) ->
            return $ subst __IMPOSSIBLE__ u
        _ -> return t
      where
        isVar0 (Var 0 [])               = True
        isVar0 (Level (Max [Plus 0 l])) = case l of
          NeutralLevel v   -> isVar0 v
          UnreducedLevel v -> isVar0 v
          BlockedLevel{}   -> False
          MetaLevel{}      -> False
        isVar0 _ = False
        allowed imp h' = h == h' && (imp || h == NotHidden)
    eta t@(Con c args) = do
      r <- getConstructorData c
      ifM (isEtaRecord r)
          (etaContractRecord r c args)
          (return t)
    eta t = return t
