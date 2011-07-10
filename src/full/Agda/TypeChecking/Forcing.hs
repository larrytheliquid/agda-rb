{-# LANGUAGE CPP #-}
module Agda.TypeChecking.Forcing where

import Control.Applicative

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute
import Agda.Utils.Size
import Agda.Utils.Monad
import Agda.Interaction.Options
import Agda.TypeChecking.Monad.Options

import Agda.Utils.Impossible
#include "../undefined.h"

addForcingAnnotations :: Type -> TCM Type
addForcingAnnotations t =
  ifM (not . optForcing <$> commandLineOptions)
      (return t) $ do
  -- t <- normalise t
  let TelV tel (El _ a) = telView' t
      n  = size tel
      indexToLevel x = n - x - 1
  xs <- filter (>=0) . map indexToLevel <$> forcedVariables a
  let t' = force xs t
  reportSLn "tc.force" 10 $ unlines
    [ "Forcing analysis"
    , "  xs = " ++ show xs
    , "  t  = " ++ show t
    , "  t' = " ++ show t'
    ]
  return t'

forcedVariables :: Term -> TCM [Nat]
forcedVariables t = case t of
  Var i [] -> return [i]
  Con _ vs -> forcedArgs vs
  Def d vs ->
    ifM (isInj d)
        (forcedArgs vs)
        (return [])
  Fun a b -> (++) <$> forcedVariables (unEl $ unArg a)
                  <*> forcedVariables (unEl b)
  Pi a b -> (++) <$> forcedVariables (unEl $ unArg a)
                 <*> (underBinder <$> forcedVariables (unEl $ absBody b))
  -- Sorts?
  _ -> return []
  where
    underBinder xs = [ x - 1 | x <- xs, x /= 0 ]
    forcedArgs vs = concat <$> mapM (forcedVariables . unArg) vs
    isInj d = do
      def <- getConstInfo d
      return $ case theDef def of
        Datatype{} -> True
        Record{}   -> True
        Axiom{}    -> True
        _          -> False

force :: [Nat] -> Type -> Type
force xs t = aux 0 t
  where
    m = maximum (-1:xs)
    aux i t | i > m = t
    aux i t = case t of
      El s (Fun a b) -> El s $ Fun (upd a) (aux (i + 1) b)
      El s (Pi  a b) -> El s $ Pi  (upd a) (fmap (aux (i + 1)) b)
      _ -> __IMPOSSIBLE__
      where
        upd a | i `elem` xs = a { argRelevance = Forced }
              | otherwise   = a
