{-# LANGUAGE CPP, TypeSynonymInstances #-}
module Agda.TypeChecking.Substitute where

import Control.Monad.Identity
import Control.Monad.Reader
import Data.List hiding (sort)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set

import Agda.Syntax.Common
import Agda.Syntax.Internal

import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Free
import Agda.TypeChecking.CompiledClause

import Agda.Utils.Monad
import Agda.Utils.Size
import Agda.Utils.Permutation

#include "../undefined.h"
import Agda.Utils.Impossible

-- | Apply something to a bunch of arguments.
--   Preserves blocking tags (application can never resolve blocking).
class Apply t where
    apply :: t -> Args -> t

instance Apply Term where
    apply m [] = m
    apply m args@(a:args0) =
        case m of
            Var i args'   -> Var i (args' ++ args)
            Def c args'   -> Def c (args' ++ args)
            Con c args'   -> Con c (args' ++ args)
            Lam _ u       -> absApp u (unArg a) `apply` args0
            MetaV x args' -> MetaV x (args' ++ args)
            Lit{}         -> __IMPOSSIBLE__
            Level{}       -> __IMPOSSIBLE__
            Pi _ _        -> __IMPOSSIBLE__
            Fun _ _       -> __IMPOSSIBLE__
            Sort _        -> __IMPOSSIBLE__
            DontCare      -> __IMPOSSIBLE__

instance Apply Type where
  apply = piApply

instance Apply Sort where
  apply s [] = s
  apply s _  = __IMPOSSIBLE__

instance Subst a => Apply (Tele a) where
  apply tel               []       = tel
  apply EmptyTel          _        = __IMPOSSIBLE__
  apply (ExtendTel _ tel) (t : ts) = absApp tel (unArg t) `apply` ts

instance Apply Definition where
    apply (Defn rel x t df m c d) args = Defn rel x (piApply t args) df m c (apply d args)

instance Apply Defn where
  apply d args = case d of
    Axiom{} -> d
    Function{ funClauses = cs, funCompiled = cc, funInv = inv
            , funProjection = mn, funArgOccurrences = occ } ->
      d { funClauses    = apply cs args
        , funCompiled   = apply cc args
        , funInv        = apply inv args
        , funProjection = fmap (nonNeg . \ n -> n - size args) mn
        , funArgOccurrences = drop (length args) occ
        } where nonNeg n = if n >= 0 then n else __IMPOSSIBLE__
    Datatype{ dataPars = np, dataClause = cl
            , dataArgOccurrences = occ } ->
      d { dataPars = np - size args, dataClause = apply cl args
        , dataArgOccurrences = drop (length args) occ
        }
    Record{ recPars = np, recConType = t, recClause = cl, recTel = tel
          , recArgOccurrences = occ } ->
      d { recPars = np - size args, recConType = apply t args
        , recClause = apply cl args, recTel = apply tel args
        , recArgOccurrences = drop (length args) occ
        }
    Constructor{ conPars = np } ->
      d { conPars = np - size args }
    Primitive{ primClauses = cs } ->
      d { primClauses = apply cs args }

instance Apply PrimFun where
    apply (PrimFun x ar def) args   = PrimFun x (ar - size args) $ \vs -> def (args ++ vs)

instance Apply Clause where
    apply (Clause r tel perm ps b) args =
      Clause r (apply tel args) (apply perm args)
             (drop (size args) ps) (apply b args)

instance Apply CompiledClauses where
  apply cc args = case cc of
    Fail     -> Fail
    Done m t
      | m >= len  -> Done (m - len) (substs ([ Var (fromIntegral i) []
                                             | i <- [0..m - len - 1]] ++
                                             map unArg args) t)
      | otherwise -> __IMPOSSIBLE__
    Case n bs
      | n >= len  -> Case (n - len) (apply bs args)
      | otherwise -> __IMPOSSIBLE__
    where
      len = length args

instance Apply a => Apply (Case a) where
  apply (Branches cs ls m) args =
    Branches (apply cs args) (apply ls args) (apply m args)

instance Apply FunctionInverse where
  apply NotInjective  args = NotInjective
  apply (Inverse inv) args = Inverse $ apply inv args

instance Apply ClauseBody where
    apply  b               []       = b
    apply (Bind (Abs _ b)) (a:args) = subst (unArg a) b `apply` args
    apply (NoBind b)       (_:args) = b `apply` args
    apply (Body _)         (_:_)    = __IMPOSSIBLE__
    apply  NoBody           _       = NoBody

instance Apply DisplayTerm where
  apply (DTerm v)          args = DTerm $ apply v args
  apply (DDot v)           args = DDot  $ apply v args
  apply (DCon c vs)        args = DCon c $ vs ++ map (fmap DTerm) args
  apply (DDef c vs)        args = DDef c $ vs ++ map (fmap DTerm) args
  apply (DWithApp v args') args = DWithApp v $ args' ++ args

instance Apply t => Apply [t] where
    apply ts args = map (`apply` args) ts

instance Apply t => Apply (Blocked t) where
    apply b args = fmap (`apply` args) b

instance Apply t => Apply (Maybe t) where
  apply x args = fmap (`apply` args) x

instance Apply v => Apply (Map k v) where
  apply x args = fmap (`apply` args) x

instance (Apply a, Apply b) => Apply (a,b) where
    apply (x,y) args = (apply x args, apply y args)

instance (Apply a, Apply b, Apply c) => Apply (a,b,c) where
    apply (x,y,z) args = (apply x args, apply y args, apply z args)

instance Apply Permutation where
  -- The permutation must start with [0..m - 1]
  apply (Perm n xs) args = Perm (n - m) $ map (flip (-) m) $ genericDrop m xs
    where
      m = size args

instance Abstract Permutation where
  abstract tel (Perm n xs) = Perm (n + m) $ [0..m - 1] ++ map (+ m) xs
    where
      m = size tel

-- | The type must contain the right number of pis without have to perform any
-- reduction.
piApply :: Type -> Args -> Type
piApply t []                      = t
piApply (El _ (Pi  _ b)) (a:args) = absApp b (unArg a) `piApply` args
piApply (El _ (Fun _ b)) (_:args) = b `piApply` args
piApply _ _                       = __IMPOSSIBLE__

-- | @(abstract args v) args --> v[args]@.
class Abstract t where
    abstract :: Telescope -> t -> t

instance Abstract Term where
    abstract = teleLam

instance Abstract Type where
    abstract = telePi_

instance Abstract Sort where
    abstract EmptyTel s = s
    abstract _        s = __IMPOSSIBLE__

instance Abstract Telescope where
  abstract  EmptyTel            tel = tel
  abstract (ExtendTel arg tel') tel = ExtendTel arg $ fmap (`abstract` tel) tel'

instance Abstract Definition where
    abstract tel (Defn rel x t df m c d) = Defn rel x (abstract tel t) df m c (abstract tel d)

instance Abstract Defn where
  abstract tel d = case d of
    Axiom{} -> d
    Function{ funClauses = cs, funCompiled = cc, funInv = inv
            , funProjection = mn, funArgOccurrences = occ } ->
      d { funClauses = abstract tel cs, funCompiled = abstract tel cc
        , funInv = abstract tel inv
        , funProjection = fmap ((+) (size tel)) mn
          -- index of record arg shifts back by number of new args
        , funArgOccurrences = replicate (size tel) Negative ++ occ -- TODO: check occurrence
        }
    Datatype{ dataPars = np, dataClause = cl, dataArgOccurrences = occ } ->
      d { dataPars = np + size tel, dataClause = abstract tel cl
        , dataArgOccurrences = replicate (size tel) Negative ++ occ -- TODO: check occurrence
        }
    Record{ recPars = np, recConType = t, recClause = cl, recTel = tel'
          , recArgOccurrences = occ } ->
      d { recPars = np + size tel, recConType = abstract tel t
        , recClause = abstract tel cl, recTel = abstract tel tel'
        , recArgOccurrences = replicate (size tel) Negative ++ occ -- TODO: check occurrence
        }
    Constructor{ conPars = np } ->
      d { conPars = np + size tel }
    Primitive{ primClauses = cs } ->
      d { primClauses = abstract tel cs }

instance Abstract PrimFun where
    abstract tel (PrimFun x ar def) = PrimFun x (ar + n) $ \ts -> def $ genericDrop n ts
        where n = size tel

instance Abstract Clause where
  abstract tel (Clause r tel' perm ps b) =
    Clause r (abstract tel tel') (abstract tel perm)
           (telVars tel ++ ps) (abstract tel b)

instance Abstract CompiledClauses where
  abstract tel Fail = Fail
  abstract tel (Done m t) = Done (m + fromIntegral (size tel)) t
  abstract tel (Case n bs) =
    Case (n + fromIntegral (size tel)) (abstract tel bs)

instance Abstract a => Abstract (Case a) where
  abstract tel (Branches cs ls m) =
    Branches (abstract tel cs) (abstract tel ls) (abstract tel m)

telVars EmptyTel                    = []
telVars (ExtendTel arg (Abs x tel)) = fmap (const $ VarP x) arg : telVars tel

instance Abstract FunctionInverse where
  abstract tel NotInjective  = NotInjective
  abstract tel (Inverse inv) = Inverse $ abstract tel inv

instance Abstract ClauseBody where
  abstract EmptyTel          b = b
  abstract (ExtendTel _ tel) b = Bind $ fmap (`abstract` b) tel

instance Abstract t => Abstract [t] where
  abstract tel = map (abstract tel)

instance Abstract t => Abstract (Maybe t) where
  abstract tel x = fmap (abstract tel) x

instance Abstract v => Abstract (Map k v) where
  abstract tel m = fmap (abstract tel) m

abstractArgs :: Abstract a => Args -> a -> a
abstractArgs args x = abstract tel x
    where
        tel   = foldr (\(Arg h r x) -> ExtendTel (Arg h r $ sort Prop) . Abs x) EmptyTel
              $ zipWith (fmap . const) names args
        names = cycle $ map (:[]) ['a'..'z']

-- | Substitutions.

type Substitution = [Term]

-- | Substitute a term for the nth free variable.
--
class Subst t where
    substs     :: Substitution -> t -> t
    substUnder :: Nat -> Term -> t -> t

idSub :: Telescope -> Substitution
idSub tel = [ Var i [] | i <- [0..size tel - 1] ]

subst :: Subst t => Term -> t -> t
subst u t = substUnder 0 u t

instance Subst Term where
    substs us t =
        case t of
            Var i vs   -> (us !!! i) `apply` substs us vs
            Lam h m    -> Lam h $ substs us m
            Def c vs   -> Def c $ substs us vs
            Con c vs   -> Con c $ substs us vs
            MetaV x vs -> MetaV x $ substs us vs
            Lit l      -> Lit l
            Level l    -> levelTm $ substs us l
            Pi a b     -> uncurry Pi $ substs us (a,b)
            Fun a b    -> uncurry Fun $ substs us (a,b)
            Sort s     -> sortTm $ substs us s
            DontCare   -> DontCare
        where
            []     !!! n = __IMPOSSIBLE__
            (x:xs) !!! 0 = x
            (_:xs) !!! n = xs !!! (n - 1)
    substUnder n u t =
        case t of
            Var i vs
              | i == n    -> raise n u `apply` substUnder n u vs
              | i < n     -> Var i $ substUnder n u vs
              | otherwise -> Var (i - 1) $ substUnder n u vs
            Lam h m    -> Lam h $ substUnder n u m
            Def c vs   -> Def c $ substUnder n u vs
            Con c vs   -> Con c $ substUnder n u vs
            MetaV x vs -> MetaV x $ substUnder n u vs
            Level l    -> levelTm $ substUnder n u l
            Lit l      -> Lit l
            Pi a b     -> uncurry Pi $ substUnder n u (a,b)
            Fun a b    -> uncurry Fun $ substUnder n u (a,b)
            Sort s     -> sortTm $ substUnder n u s
            DontCare   -> DontCare

instance Subst Type where
    substs us (El s t) = substs us s `El` substs us t
    substUnder n u (El s t) = substUnder n u s `El` substUnder n u t

instance Subst Sort where
    substs us s = case s of
      Type n     -> levelSort $ sub n
      Prop       -> Prop
      Inf        -> Inf
      DLub s1 s2 -> DLub (sub s1) (sub s2)
      where sub x = substs us x

    substUnder n u s = case s of
      Type n     -> levelSort $ sub n
      Prop       -> Prop
      Inf        -> Inf
      DLub s1 s2 -> DLub (sub s1) (sub s2)
      where sub x = substUnder n u x

instance Subst Level where
  substs us (Max as) = Max $ substs us as
  substUnder n u (Max as) = Max $ substUnder n u as

instance Subst PlusLevel where
  substs us l@ClosedLevel{} = l
  substs us (Plus n l) = Plus n $ substs us l
  substUnder n u l@ClosedLevel{} = l
  substUnder n u (Plus m l) = Plus m $ substUnder n u l

instance Subst LevelAtom where
  substs us      (MetaLevel m vs)   = MetaLevel m    $ substs us vs
  substs us      (BlockedLevel m v) = BlockedLevel m $ substs us v
  substs us      (NeutralLevel v)   = UnreducedLevel $ substs us v
  substs us      (UnreducedLevel v) = UnreducedLevel $ substs us v
  substUnder n u (MetaLevel m vs)   = MetaLevel m    $ substUnder n u vs
  substUnder n u (BlockedLevel m v) = BlockedLevel m $ substUnder n u v
  substUnder n u (NeutralLevel v)   = UnreducedLevel $ substUnder n u v
  substUnder n u (UnreducedLevel v) = UnreducedLevel $ substUnder n u v

instance Subst Pattern where
  substs us p = case p of
    VarP s       -> VarP s
    LitP l       -> LitP l
    ConP c mt ps -> ConP c (substs us mt) $ substs us ps
    DotP t       -> DotP $ substs us t
  substUnder n u p = case p of
    VarP s       -> VarP s
    LitP l       -> LitP l
    ConP c mt ps -> ConP c (substUnder n u mt) $ substUnder n u ps
    DotP t       -> DotP $ substUnder n u t

instance Subst t => Subst (Blocked t) where
    substs us b      = fmap (substs us) b
    substUnder n u b = fmap (substUnder n u) b

instance Subst DisplayTerm where
  substs us      (DTerm v)        = DTerm $ substs us v
  substs us      (DDot v)         = DDot  $ substs us v
  substs us      (DCon c vs)      = DCon c $ substs us vs
  substs us      (DDef c vs)      = DDef c $ substs us vs
  substs us      (DWithApp vs ws) = uncurry DWithApp $ substs us (vs, ws)
  substUnder n u (DTerm v)        = DTerm $ substUnder n u v
  substUnder n u (DDot  v)        = DDot  $ substUnder n u v
  substUnder n u (DCon c vs)      = DCon c $ substUnder n u vs
  substUnder n u (DDef c vs)      = DDef c $ substUnder n u vs
  substUnder n u (DWithApp vs ws) = uncurry DWithApp $ substUnder n u (vs, ws)

instance Subst a => Subst (Tele a) where
  substs us  EmptyTel              = EmptyTel
  substs us (ExtendTel t tel)      = uncurry ExtendTel $ substs us (t, tel)
  substUnder n u  EmptyTel         = EmptyTel
  substUnder n u (ExtendTel t tel) = uncurry ExtendTel $ substUnder n u (t, tel)

instance Subst a => Subst (Abs a) where
    substs us      (Abs x t) = Abs x $ substs (Var 0 [] : raise 1 us) t
    substUnder n u (Abs x t) = Abs x $ substUnder (n + 1) u t

instance Subst a => Subst (Arg a) where
    substs us      = fmap (substs us)
    substUnder n u = fmap (substUnder n u)

instance Subst a => Subst (Maybe a) where
  substs us      = fmap (substs us)
  substUnder n u = fmap (substUnder n u)

instance Subst a => Subst [a] where
    substs us      = map (substs us)
    substUnder n u = map (substUnder n u)

instance (Subst a, Subst b) => Subst (a,b) where
    substs us (x,y)      = (substs us x, substs us y)
    substUnder n u (x,y) = (substUnder n u x, substUnder n u y)

instance Subst ClauseBody where
    substs us (Body t)        = Body $ substs us t
    substs us (Bind b)        = Bind $ substs us b
    substs us (NoBind b)      = NoBind $ substs us b
    substs _   NoBody         = NoBody
    substUnder n u (Body t)   = Body $ substUnder n u t
    substUnder n u (Bind b)   = Bind $ substUnder n u b
    substUnder n u (NoBind b) = NoBind $ substUnder n u b
    substUnder _ _   NoBody   = NoBody

-- | Instantiate an abstraction
absApp :: Subst t => Abs t -> Term -> t
absApp (Abs _ v) u = subst u v

-- | Add @k@ to index of each open variable in @x@.
class Raise t where
    raiseFrom :: Nat -> Nat -> t -> t
    renameFrom :: Nat -> (Nat -> Nat) -> t -> t

instance Raise Term where
    raiseFrom m k v =
        case v of
            Var i vs
                | i < m     -> Var i $ rf vs
                | otherwise -> Var (i + k) $ rf vs
            Lam h m         -> Lam h $ rf m
            Def c vs        -> Def c $ rf vs
            Con c vs        -> Con c $ rf vs
            MetaV x vs      -> MetaV x $ rf vs
            Level l         -> Level $ rf l
            Lit l           -> Lit l
            Pi a b          -> uncurry Pi $ rf (a,b)
            Fun a b         -> uncurry Fun $ rf (a,b)
            Sort s          -> Sort $ rf s
            DontCare        -> DontCare
        where
            rf x = raiseFrom m k x

    renameFrom m k v =
        case v of
            Var i vs
                | i < m     -> Var i $ rf vs
                | otherwise -> Var (k (i - m) + m) $ rf vs
            Lam h m         -> Lam h $ rf m
            Def c vs        -> Def c $ rf vs
            Con c vs        -> Con c $ rf vs
            MetaV x vs      -> MetaV x $ rf vs
            Level l         -> Level $ rf l
            Lit l           -> Lit l
            Pi a b          -> uncurry Pi $ rf (a,b)
            Fun a b         -> uncurry Fun $ rf (a,b)
            Sort s          -> Sort $ rf s
            DontCare        -> DontCare
        where
            rf x = renameFrom m k x

instance Raise Type where
    raiseFrom m k (El s t) = raiseFrom m k s `El` raiseFrom m k t
    renameFrom m k (El s t) = renameFrom m k s `El` renameFrom m k t

instance Raise Sort where
    raiseFrom m k s = case s of
      Type n     -> Type $ rf n
      Prop       -> Prop
      Inf        -> Inf
      DLub s1 s2 -> DLub (rf s1) (rf s2)
      where rf x = raiseFrom m k x

    renameFrom m k s = case s of
      Type n     -> Type $ rf n
      Prop       -> Prop
      Inf        -> Inf
      DLub s1 s2 -> DLub (rf s1) (rf s2)
      where rf x = renameFrom m k x

instance Raise Level where
  raiseFrom m k (Max as) = Max $ raiseFrom m k as
  renameFrom m k (Max as) = Max $ renameFrom m k as

instance Raise PlusLevel where
  raiseFrom m k l@ClosedLevel{} = l
  raiseFrom m k (Plus n l) = Plus n $ raiseFrom m k l
  renameFrom m k l@ClosedLevel{} = l
  renameFrom m k (Plus n l) = Plus n $ renameFrom m k l

instance Raise LevelAtom where
  raiseFrom m k l = case l of
    MetaLevel n vs   -> MetaLevel n $ raiseFrom m k vs
    NeutralLevel v   -> NeutralLevel $ raiseFrom m k v
    BlockedLevel n v -> BlockedLevel n $ raiseFrom m k v
    UnreducedLevel v -> UnreducedLevel $ raiseFrom m k v
  renameFrom m k l = case l of
    MetaLevel n vs   -> MetaLevel n $ renameFrom m k vs
    NeutralLevel v   -> NeutralLevel $ renameFrom m k v
    BlockedLevel n v -> BlockedLevel n $ renameFrom m k v
    UnreducedLevel v -> UnreducedLevel $ renameFrom m k v

-- Andreas, 2010-09-09 raise dot patterns and type info embedded in a pattern
instance Raise Pattern where
    raiseFrom m k p = case p of
      DotP t -> DotP $ raiseFrom m k t
      ConP c mt ps -> ConP c (raiseFrom m k mt) (raiseFrom m k ps)
      VarP x -> p
      LitP l -> p
    renameFrom m k p = case p of
      DotP t -> DotP $ renameFrom m k t
      ConP c mt ps -> ConP c (renameFrom m k mt) (renameFrom m k ps)
      VarP x -> p
      LitP l -> p

instance Raise a => Raise (Tele a) where
    raiseFrom m k EmptyTel          = EmptyTel
    raiseFrom m k (ExtendTel a tel) = uncurry ExtendTel $ raiseFrom m k (a, tel)
    renameFrom m k EmptyTel          = EmptyTel
    renameFrom m k (ExtendTel a tel) = uncurry ExtendTel $ renameFrom m k (a, tel)

instance Raise DisplayForm where
  raiseFrom m k (Display n ps v) = Display n (raiseFrom (m + 1) k ps)
                                             (raiseFrom (m + n) k v)
  renameFrom m k (Display n ps v) = Display n (renameFrom (m + 1) k ps)
                                             (renameFrom (m + n) k v)

instance Raise DisplayTerm where
  raiseFrom m k (DWithApp xs ys) = uncurry DWithApp $ raiseFrom m k (xs, ys)
  raiseFrom m k (DTerm v)        = DTerm $ raiseFrom m k v
  raiseFrom m k (DDot  v)        = DDot  $ raiseFrom m k v
  raiseFrom m k (DCon c vs)      = DCon c $ raiseFrom m k vs
  raiseFrom m k (DDef c vs)      = DDef c $ raiseFrom m k vs
  renameFrom m k (DWithApp xs ys) = uncurry DWithApp $ renameFrom m k (xs, ys)
  renameFrom m k (DTerm v)        = DTerm $ renameFrom m k v
  renameFrom m k (DDot  v)        = DDot  $ renameFrom m k v
  renameFrom m k (DCon c vs)      = DCon c $ renameFrom m k vs
  renameFrom m k (DDef c vs)      = DDef c $ renameFrom m k vs

instance Raise t => Raise (Abs t) where
    raiseFrom m k = fmap (raiseFrom (m + 1) k)
    renameFrom m k = fmap (renameFrom (m + 1) k)

instance Raise t => Raise (Arg t) where
    raiseFrom m k = fmap (raiseFrom m k)
    renameFrom m k = fmap (renameFrom m k)

instance Raise t => Raise (Blocked t) where
    raiseFrom m k = fmap (raiseFrom m k)
    renameFrom m k = fmap (renameFrom m k)

instance Raise t => Raise [t] where
    raiseFrom m k = fmap (raiseFrom m k)
    renameFrom m k = fmap (renameFrom m k)

instance Raise t => Raise (Maybe t) where
    raiseFrom m k = fmap (raiseFrom m k)
    renameFrom m k = fmap (renameFrom m k)

instance Raise v => Raise (Map k v) where
    raiseFrom m k = fmap (raiseFrom m k)
    renameFrom m k = fmap (renameFrom m k)

instance (Raise a, Raise b) => Raise (a,b) where
    raiseFrom m k (x,y) = (raiseFrom m k x, raiseFrom m k y)
    renameFrom m k (x,y) = (renameFrom m k x, renameFrom m k y)

raise :: Raise t => Nat -> t -> t
raise = raiseFrom 0

rename :: Raise t => (Nat -> Nat) -> t -> t
rename = renameFrom 0

data TelView = TelV Telescope Type

telView' :: Type -> TelView
telView' t = case unEl t of
  Pi a (Abs x b)  -> absV a x $ telView' b
  Fun a b         -> absV a "_" $ telView' (raise 1 b)
  _               -> TelV EmptyTel t
  where
    absV a x (TelV tel t) = TelV (ExtendTel a (Abs x tel)) t

telePi :: Telescope -> Type -> Type
telePi  EmptyTel         t = t
telePi (ExtendTel u tel) t = el $ fn u b
  where
    el = El (dLub s1 s2)
    b = fmap (flip telePi t) tel
    s1 = getSort $ unArg u
    s2 = fmap getSort b

    fn a b
      | 0 `freeIn` absBody b = Pi a b
      | otherwise            = Fun a $ absApp b __IMPOSSIBLE__

-- | Everything will be a pi.
telePi_ :: Telescope -> Type -> Type
telePi_  EmptyTel        t = t
telePi_ (ExtendTel u tel) t = el $ Pi u b
  where
    el = El (dLub s1 s2)
    b  = fmap (flip telePi_ t) tel
    s1 = getSort $ unArg u
    s2 = fmap getSort b

-- | Dependent least upper bound, to assign a level to expressions
--   like @forall i -> Set i@.
--
--   @dLub s1 \i.s2 = \omega@ if @i@ appears in the rigid variables of @s2@.
dLub :: Sort -> Abs Sort -> Sort
dLub s1 s2
  | 0 `Set.member` rv = Inf
  | 0 `Set.member` fv = DLub s1 s2
  | otherwise         = sLub s1 (absApp s2 __IMPOSSIBLE__)
  where
    vs = freeVars (absBody s2)
    fv = flexibleVars vs
    rv = rigidVars vs
