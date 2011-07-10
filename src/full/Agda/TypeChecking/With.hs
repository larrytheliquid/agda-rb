{-# LANGUAGE CPP #-}
module Agda.TypeChecking.With where

import Control.Applicative
import Control.Monad
import Control.Monad.State
import qualified Data.Traversable as T (mapM)
import Data.List

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Abstract (LHS(..), RHS(..))
import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Position

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Primitive hiding (Nat)
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Rules.LHS.Implicit
import Agda.TypeChecking.Rules.LHS.Split (expandLitPattern)
import Agda.TypeChecking.Abstract
import Agda.TypeChecking.EtaContract
import Agda.TypeChecking.Telescope

import Agda.Utils.Permutation
import Agda.Utils.Size

#include "../undefined.h"
import Agda.Utils.Impossible

showPat (VarP x)              = text x
showPat (DotP t)              = comma <> text (showsPrec 10 t "")
showPat (ConP c Nothing ps)   = parens $ prettyTCM c <+> fsep (map (showPat . unArg) ps)
showPat (ConP c (Just t) ps)  = parens $ prettyTCM c <+> fsep (map (showPat . unArg) ps) <+> text ":" <+> prettyTCM t
showPat (LitP l)              = text (show l)

withFunctionType :: Telescope -> [Term] -> [Type] -> Telescope -> Type -> TCM Type
withFunctionType delta1 vs as delta2 b = {-dontEtaContractImplicit $-} do
  (vas, b) <- addCtxTel delta1 $ do
    vs <- etaContract =<< normalise vs
    as <- etaContract =<< normalise as
    b  <- etaContract =<< normalise (telePi_ delta2 b)
    reportSDoc "tc.with.abstract" 40 $
      sep [ text "abstracting"
          , nest 2 $ vcat
            [ text "vs = " <+> prettyTCM vs
            , text "as = " <+> prettyTCM as
            , text "b  = " <+> prettyTCM b ] ]
    reportSLn "tc.with.abstract" 50 $ "  raw vs = " ++ show vs ++ "\n  raw b  = " ++ show b
    return (zip vs as, b)
  return $ telePi_ delta1 $ foldr (uncurry piAbstractTerm) b vas

-- | Compute the clauses for the with-function given the original patterns.
buildWithFunction :: QName -> Telescope -> [Arg Pattern] -> Permutation ->
                     Nat -> Nat -> [A.Clause] -> TCM [A.Clause]
buildWithFunction aux gamma qs perm n1 n cs = mapM buildWithClause cs
  where
    buildWithClause (A.Clause (LHS i _ ps wps) rhs wh) = do
      let (wps0, wps1) = genericSplitAt n wps
          ps0          = map (defaultArg . unnamed) wps0
      rhs <- buildRHS rhs
      (ps1, ps2)  <- genericSplitAt n1 <$> stripWithClausePatterns gamma qs perm ps
      let result = A.Clause (LHS i aux (ps1 ++ ps0 ++ ps2) wps1) rhs wh
      reportSDoc "tc.with" 20 $ vcat
        [ text "buildWithClause returns" <+> prettyA result
        ]
      return result

    buildRHS rhs@(RHS _)               = return rhs
    buildRHS rhs@AbsurdRHS             = return rhs
    buildRHS (WithRHS q es cs)         = WithRHS q es <$> mapM buildWithClause cs
    buildRHS (RewriteRHS q eqs rhs wh) = flip (RewriteRHS q eqs) wh <$> buildRHS rhs

{-| @stripWithClausePatterns Γ qs π ps = ps'@

    @Δ@ - context bound by lhs of original function (not an argument)

    @Γ@ - type of arguments to original function

    @qs@ - internal patterns for original function

    @π@ - permutation taking @vars(qs)@ to @support(Δ)@

    @ps@ - patterns in with clause (presumably of type @Γ@)

    @ps'@ - patterns for with function (presumably of type @Δ@)
-}
stripWithClausePatterns :: Telescope -> [Arg Pattern] -> Permutation -> [NamedArg A.Pattern] -> TCM [NamedArg A.Pattern]
stripWithClausePatterns gamma qs perm ps = do
  psi <- insertImplicitPatterns ps gamma
  unless (size psi == size gamma) $ fail $ "wrong number of arguments in with clause: given " ++ show (size psi) ++ ", expected " ++ show (size gamma)
  reportSDoc "tc.with.strip" 10 $ vcat
    [ text "stripping patterns"
    , nest 2 $ text "gamma = " <+> prettyTCM gamma
    , nest 2 $ text "psi = " <+> fsep (punctuate comma $ map prettyA psi)
    , nest 2 $ text "qs  = " <+> fsep (punctuate comma $ map (showPat . unArg) qs)
    ]
  ps' <- strip gamma psi qs
  let psp = permute perm ps'
  reportSDoc "tc.with.strip" 10 $ vcat
    [ nest 2 $ text "ps' = " <+> fsep (punctuate comma $ map prettyA ps')
    , nest 2 $ text "psp = " <+> fsep (punctuate comma $ map prettyA $ psp)
    ]
  return psp
  where
    -- implicit args inserted at top level
    -- all three arguments should have the same size
    strip :: Telescope -> [NamedArg A.Pattern] -> [Arg Pattern] -> TCM [NamedArg A.Pattern]
    strip _           []      (_ : _) = __IMPOSSIBLE__
    strip _           (_ : _) []      = __IMPOSSIBLE__
    strip EmptyTel    (_ : _) _       = __IMPOSSIBLE__
    strip ExtendTel{} []      _       = __IMPOSSIBLE__
    strip EmptyTel    []      []      | 0 == 0 = return []
    strip (ExtendTel a tel) (p0 : ps) (q : qs) = do
      p <- expandLitPattern p0
      reportSDoc "tc.with.strip" 15 $ vcat
        [ text "strip"
        , nest 2 $ text "ps  =" <+> fsep (punctuate comma $ map prettyA (p0 : ps))
        , nest 2 $ text "exp =" <+> prettyA p
        , nest 2 $ text "qs  =" <+> fsep (punctuate comma $ map (showPat . unArg) (q : qs))
        , nest 2 $ text "tel =" <+> prettyTCM (ExtendTel a tel)
        ]
      case unArg q of
        VarP _  -> do
          ps <- underAbstraction a tel $ \tel -> strip tel ps qs
          return $ p : ps

        DotP v  -> case namedThing $ unArg p of
          A.DotP _ _    -> ok
          A.ImplicitP _ -> ok
          _ -> do
            d <- prettyA p
            typeError $ GenericError $
                "Inaccessible (dotted) patterns from the parent clause must " ++
                "also be inaccesible in the with clause, when checking the " ++
                "pattern " ++ show d ++ ","
          where
            ok = do
              ps <- strip (tel `absApp` v) ps qs
              return $ p : ps

        ConP c _ qs' -> case namedThing $ unArg p of
          A.ConP _ (A.AmbQ cs') ps' -> do

            Con c' [] <- constructorForm =<< reduce (Con c [])
            c <- return $ c' `withRangeOf` c
            let getCon (Con c []) = c
                getCon _ = __IMPOSSIBLE__
            cs' <- map getCon <$> (mapM constructorForm =<< mapM (\c' -> reduce $ Con c' []) cs')

            unless (elem c cs') mismatch

            -- The type is a datatype
            Def d us <- normalise $ unEl (unArg a)

            -- Compute the argument telescope for the constructor
            Con c []    <- constructorForm =<< normalise (Con c [])
            Defn {defType = ct, theDef = Constructor{conPars = np}}  <- getConstInfo c
            let ct' = ct `apply` genericTake np us
            TelV tel' _ <- telView ct'

            reportSDoc "tc.with.strip" 20 $
              vcat [ text "ct  = " <+> prettyTCM ct
                   , text "ct' = " <+> prettyTCM ct'
                   , text "np  = " <+> text (show np)
                   , text "us  = " <+> prettyList (map prettyTCM us)
                   , text "us' = " <+> prettyList (map prettyTCM $ genericTake np us)
                   ]

            -- Compute the new telescope
            let v     = Con c $ reverse [ Arg h r (Var i []) | (i, Arg h r _) <- zip [0..] $ reverse qs' ]
                tel'' = tel' `abstract` absApp (raise (size tel') tel) v

            reportSDoc "tc.with.strip" 15 $ sep
              [ text "inserting implicit"
              , nest 2 $ prettyList $ map prettyA (ps' ++ ps)
              , nest 2 $ text ":" <+> prettyTCM tel''
              ]

            -- Insert implicit patterns (just for the constructor arguments)
            psi' <- insertImplicitPatterns ps' tel'
            unless (size psi' == size tel') $ typeError $ WrongNumberOfConstructorArguments c (size tel') (size psi')

            -- Do it again for everything (is this necessary?)
            psi' <- insertImplicitPatterns (psi' ++ ps) tel''

            -- Keep going
            strip tel'' psi' (qs' ++ qs)
          _ -> mismatch

        LitP lit -> case namedThing $ unArg p of
          A.LitP lit' | lit == lit' -> strip (tel `absApp` Lit lit) ps qs
          _ -> mismatch
      where
        mismatch = typeError $ WithClausePatternMismatch (namedThing $ unArg p0) (unArg q)
    strip tel ps qs = error $ "huh? " ++ show (size tel) ++ " " ++ show (size ps) ++ " " ++ show (size qs)

-- | Construct the display form for a with function. It will display
--   applications of the with function as applications to the original function.
--   For instance, @aux a b c@ as @f (suc a) (suc b) | c@
withDisplayForm :: QName -> QName -> Telescope -> Telescope -> Nat -> [Arg Pattern] -> Permutation -> TCM DisplayForm
withDisplayForm f aux delta1 delta2 n qs perm = do
  topArgs <- raise (n + size delta1 + size delta2) <$> getContextArgs
  x <- freshNoName_
  let wild = Def (qualify (mnameFromList []) x) []

  let top = genericLength topArgs
      vs = map (fmap DTerm) topArgs ++ raiseFrom (size delta2) n (substs (sub wild) $ patsToTerms qs)
      dt = DWithApp (DDef f vs : map DTerm withArgs) []
      withArgs = reverse $ map var [size delta2..size delta2 + n - 1]
      pats = genericReplicate (n + size delta1 + size delta2 + top) (Var 0 [])

  let display = Display (n + size delta1 + size delta2 + top) pats dt

  reportSDoc "tc.with.display" 20 $ vcat
    [ text "withDisplayForm"
    , nest 2 $ vcat
      [ text "f      =" <+> text (show f)
      , text "aux    =" <+> text (show aux)
      , text "delta1 =" <+> prettyTCM delta1
      , text "delta2 =" <+> prettyTCM delta2
      , text "perm   =" <+> text (show perm)
      , text "qs     =" <+> text (show qs)
      , text "dt     =" <+> prettyTCM dt
      , text "raw    =" <+> text (show display)
      , text "qsToTm =" <+> prettyTCM (patsToTerms qs)
      , text "sub qs =" <+> prettyTCM (substs (sub wild) $ patsToTerms qs)
      ]
    ]

  return display
  where
    var i = Var i []
    sub wild = map term [0..] -- m - 1]
      where
        Perm m xs = reverseP perm
        -- Perm m xs = perm    -- thinking required.. but ignored
                            -- dropping the reverse seems to work better
                            -- Andreas, 2010-09-09: I DISAGREE.
        term i = case findIndex (i ==) xs of
          Nothing -> wild
          Just j  -> Var (fromIntegral j) []

{- example (test/fail/Issue295.agda)

  aux  = aux d w a b c
  delta1 = d
  delta2 = a b c
  perm = x0,x1,x2,x3 -> x3,x0,x1,x2
  perm = a,b,c,d -> d,a,b,c
WIHOUT reverseP IS:
  dt   = (@0 ⟶ @4) ﹔ (@2 ⟶ @1) | @3
  dt   = (c ⟶ d) ﹔ (a ⟶ b) | w
WITH reverseP IS, AS IT SHOULD:
  dt   = (a ⟶ b) ﹔ (c ⟶ d) | w
  dt   = (@2 ⟶ @1) ﹔ (@0 ⟶ @4) | @3
-}

patsToTerms :: [Arg Pattern] -> [Arg DisplayTerm]
patsToTerms ps = evalState (toTerms ps) 0
  where
    mapMr f xs = reverse <$> mapM f (reverse xs)

    var :: State Nat Nat
    var = do
      i <- get
      put (i + 1)
      return i

    toTerms :: [Arg Pattern] -> State Nat [Arg DisplayTerm]
    toTerms ps = mapMr toArg ps

    toArg :: Arg Pattern -> State Nat (Arg DisplayTerm)
    toArg = T.mapM toTerm

    toTerm :: Pattern -> State Nat DisplayTerm
    toTerm p = case p of
      VarP _      -> var >>= \i -> return $ DTerm (Var i [])
      DotP t      -> return $ DDot t
      ConP c _ ps -> DCon c <$> toTerms ps
      LitP l      -> return $ DTerm (Lit l)

data ConPos = Here
            | ArgPat Int ConPos

updateWithConstructorRanges ::
  [Telescope] -> [Arg Pattern] -> A.RHS -> [Arg Pattern]
updateWithConstructorRanges tel ps A.RHS{}            = ps
updateWithConstructorRanges tel ps A.AbsurdRHS{}      = ps
updateWithConstructorRanges tel ps (A.WithRHS _ _ cs) = ps
updateWithConstructorRanges tel ps A.RewriteRHS{}     = ps

constructorsInClauses :: ConPos -> [A.Clause] -> [Range]
constructorsInClauses pos cs = concatMap (constructorsInClause pos) cs

constructorsInClause :: ConPos -> A.Clause -> [Range]
constructorsInClause pos (A.Clause (A.LHS _ _ ps wps) rhs _) = []
