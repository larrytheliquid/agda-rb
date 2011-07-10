{-# LANGUAGE CPP, PatternGuards, DeriveDataTypeable #-}

module Agda.Syntax.Concrete.Definitions
    ( NiceDeclaration(..)
    , NiceDefinition(..)
    , NiceConstructor, NiceTypeSignature
    , Clause(..)
    , DeclarationException(..)
    , Nice, runNice
    , niceDeclarations
    , notSoNiceDeclarations
    ) where

import Control.Applicative

import Data.Generics (Typeable, Data)
import qualified Data.Map as Map
import Control.Monad.Error
import Data.List
import Data.Maybe
import qualified Data.Traversable as Trav

import Agda.Syntax.Concrete
import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Fixity
import Agda.Syntax.Notation
import Agda.Syntax.Concrete.Pretty
import Agda.Utils.Pretty

#include "../../undefined.h"
import Agda.Utils.Impossible

{--------------------------------------------------------------------------
    Types
 --------------------------------------------------------------------------}

{-| The nice declarations. No fixity declarations and function definitions are
    contained in a single constructor instead of spread out between type
    signatures and clauses. The @private@, @postulate@, and @abstract@
    modifiers have been distributed to the individual declarations.
-}
data NiceDeclaration
	= Axiom Range Fixity' Access IsAbstract Relevance Name Expr
            -- ^ Axioms and functions can be declared irrelevant.
        | NiceField Range Fixity' Access IsAbstract Name (Arg Expr)
	| PrimitiveFunction Range Fixity' Access IsAbstract Name Expr
	| NiceDef Range [Declaration] [NiceTypeSignature] [NiceDefinition]
	    -- ^ A bunch of mutually recursive functions\/datatypes.
	    --   The last two lists have the same length. The first list is the
	    --   concrete declarations these definitions came from.
	| NiceModule Range Access IsAbstract QName Telescope [Declaration]
	| NiceModuleMacro Range Access IsAbstract Name ModuleApplication OpenShortHand ImportDirective
	| NiceOpen Range QName ImportDirective
	| NiceImport Range QName (Maybe AsName) OpenShortHand ImportDirective
	| NicePragma Range Pragma
    deriving (Typeable, Data)

instance Show NiceDeclaration where
  show _ = "{NiceDeclaration}"

-- | A definition without its type signature.
data NiceDefinition
	= FunDef  Range [Declaration] Fixity' Access IsAbstract Name [Clause]
	| DataDef Range Fixity' Access IsAbstract Name [LamBinding] [NiceConstructor]
	| RecDef Range Fixity' Access IsAbstract Name (Maybe NiceConstructor) [LamBinding] [NiceDeclaration]
          -- ^ The 'NiceConstructor' has a dummy type field (the
          --   record constructor type has not been computed yet).
    deriving (Typeable, Data)

-- | Only 'Axiom's.
type NiceConstructor = NiceTypeSignature

-- | Only 'Axiom's.
type NiceTypeSignature	= NiceDeclaration

-- | One clause in a function definition. There is no guarantee that the 'LHS'
--   actually declares the 'Name'. We will have to check that later.
data Clause = Clause Name LHS RHS WhereClause [Clause]
    deriving (Typeable, Data)

-- | The exception type.
data DeclarationException
	= MultipleFixityDecls [(Name, [Fixity'])]
	| MissingDefinition Name
        | MissingWithClauses Name
	| MissingTypeSignature LHS
	| NotAllowedInMutual NiceDeclaration
	| UnknownNamesInFixityDecl [Name]
        | Codata Range
	| DeclarationPanic String
    deriving (Typeable)

instance HasRange DeclarationException where
    getRange (MultipleFixityDecls xs)	   = getRange (fst $ head xs)
    getRange (MissingDefinition x)	   = getRange x
    getRange (MissingWithClauses x)        = getRange x
    getRange (MissingTypeSignature x)	   = getRange x
    getRange (NotAllowedInMutual x)	   = getRange x
    getRange (UnknownNamesInFixityDecl xs) = getRange . head $ xs
    getRange (Codata r)                    = r
    getRange (DeclarationPanic _)	   = noRange

instance HasRange NiceDeclaration where
    getRange (Axiom r _ _ _ _ _ _)	       = r
    getRange (NiceField r _ _ _ _ _)	       = r
    getRange (NiceDef r _ _ _)		       = r
    getRange (NiceModule r _ _ _ _ _)	       = r
    getRange (NiceModuleMacro r _ _ _ _ _ _)   = r
    getRange (NiceOpen r _ _)		       = r
    getRange (NiceImport r _ _ _ _)	       = r
    getRange (NicePragma r _)		       = r
    getRange (PrimitiveFunction r _ _ _ _ _)   = r

instance HasRange NiceDefinition where
  getRange (FunDef r _ _ _ _ _ _)   = r
  getRange (DataDef r _ _ _ _ _ _)  = r
  getRange (RecDef r _ _ _ _ _ _ _) = r

instance Error DeclarationException where
  noMsg  = strMsg ""
  strMsg = DeclarationPanic

instance Show DeclarationException where
  show (MultipleFixityDecls xs) = show $
    sep [ fsep $ pwords "Multiple fixity declarations for"
	, vcat $ map f xs
	]
      where
	f (x, fs) = pretty x <> text ":" <+> fsep (map (text . show) fs)
  show (MissingDefinition x) = show $ fsep $
    pwords "Missing definition for" ++ [pretty x]
  show (MissingWithClauses x) = show $ fsep $
    pwords "Missing with-clauses for function" ++ [pretty x]
  show (MissingTypeSignature x) = show $ fsep $
    pwords "Missing type signature for left hand side" ++ [pretty x]
  show (UnknownNamesInFixityDecl xs) = show $ fsep $
    pwords "Names out of scope in fixity declarations:" ++ map pretty xs
  show (NotAllowedInMutual nd) = show $ fsep $
    [text $ decl nd] ++ pwords "are not allowed in mutual blocks"
    where
      decl (Axiom{})		 = "Postulates"
      decl (NiceField{})         = "Fields"
      decl (NiceDef{})		 = "Record types"
      decl (NiceModule{})	 = "Modules"
      decl (NiceModuleMacro{})   = "Modules"
      decl (NiceOpen{})		 = "Open declarations"
      decl (NiceImport{})	 = "Import statements"
      decl (NicePragma{})	 = "Pragmas"
      decl (PrimitiveFunction{}) = "Primitive declarations"
  show (Codata _) =
    "The codata construction has been removed. " ++
    "Use the INFINITY builtin instead."
  show (DeclarationPanic s) = s

{--------------------------------------------------------------------------
    The niceifier
 --------------------------------------------------------------------------}

type Nice = Either DeclarationException

runNice :: Nice a -> Either DeclarationException a
runNice = id

niceDeclarations :: [Declaration] -> Nice [NiceDeclaration]
niceDeclarations ds = do
      fixs <- fixities ds
      case Map.keys fixs \\ concatMap declaredNames ds of
	[]  -> nice fixs ds
	xs  -> throwError $ UnknownNamesInFixityDecl xs
    where

	-- If no fixity is given we return the default fixity.
	fixity :: Name -> Map.Map Name Fixity' -> Fixity'
	fixity = Map.findWithDefault defaultFixity'

	-- We forget all fixities in recursive calls. This is because
	-- fixity declarations have to appear at the same level as the
	-- declaration.
	fmapNice x = mapM niceDeclarations x

	-- Compute the names defined in a declaration
	declaredNames :: Declaration -> [Name]
	declaredNames d = case d of
	  TypeSig _ x _				       -> [x]
          Field x _                                    -> [x]
	  FunClause (LHS p [] _ _) _ _
            | IdentP (QName x) <- noSingletonRawAppP p -> [x]
	  FunClause{}				       -> []
	  Data _ _ x _ _ cs			       -> x : concatMap declaredNames cs
	  Record _ x c _ _ _			       -> x : maybeToList c
	  Infix _ _				       -> []
          Syntax _ _                                   -> []
	  Mutual _ ds				       -> concatMap declaredNames ds
	  Abstract _ ds				       -> concatMap declaredNames ds
	  Private _ ds				       -> concatMap declaredNames ds
	  Postulate _ ds			       -> concatMap declaredNames ds
	  Primitive _ ds			       -> concatMap declaredNames ds
	  Open{}				       -> []
	  Import{}				       -> []
	  ModuleMacro{}				       -> []
	  Module{}				       -> []
	  Pragma{}				       -> []

        niceFix fixs ds = do
	  fixs <- plusFixities fixs =<< fixities ds
          nice fixs ds

	nice _ []	 = return []
	nice fixs (d:ds) =
	    case d of
		TypeSig rel x t ->
		    -- After a type signature there should follow a bunch of
		    -- clauses.
		    case span (isFunClauseOf x) ds of
			([], _)	    -> throwError $ MissingDefinition x
			(ds0,ds1)   -> do
			  ds1 <- nice fixs ds1
			  d <- mkFunDef rel fixs x (Just t) ds0
                          return $ d : ds1

		cl@(FunClause lhs@(LHS p [] _ _) _ _)
                  | IdentP (QName x) <- noSingletonRawAppP p
                                  -> do
		      ds <- nice fixs ds
		      d <- mkFunDef Relevant fixs x Nothing [cl] -- fun def without type signature is relevant
                      return $ d : ds
                FunClause lhs _ _ -> throwError $ MissingTypeSignature lhs

		_   -> liftM2 (++) nds (nice fixs ds)
		    where
			nds = case d of
                            Field x t                     -> return $ niceAxioms fixs [ d ]
			    Data r CoInductive x tel t cs -> throwError (Codata r)
			    Data r Inductive   x tel t cs -> dataOrRec DataDef niceAx r x tel t cs
			    Record r x c tel t cs         -> do
                              let c' = (\c -> niceAxiom fixs (TypeSig Relevant c t)) <$> c -- constructor is always relevant
                              dataOrRec (\x1 x2 x3 x4 x5 -> RecDef x1 x2 x3 x4 x5 c')
                                        (const niceDeclarations) r x tel t cs
			    Mutual r ds -> do
			      d <- mkMutual r [d] =<< niceFix fixs ds
			      return [d]

			    Abstract r ds -> do
			      map mkAbstract <$> niceFix fixs ds

			    Private _ ds -> do
			      map mkPrivate <$> niceFix fixs ds

			    Postulate _ ds -> return $ niceAxioms fixs ds

			    Primitive _ ds -> return $ map toPrim $ niceAxioms fixs ds

			    Module r x tel ds	-> return
				[ NiceModule r PublicAccess ConcreteDef x tel ds ]

			    ModuleMacro r x modapp op is -> return
				[ NiceModuleMacro r PublicAccess ConcreteDef x modapp op is ]

			    Infix _ _		-> return []
			    Syntax _ _		-> return []
			    Open r x is		-> return [NiceOpen r x is]
			    Import r x as op is	-> return [NiceImport r x as op is]

			    Pragma p		-> return [NicePragma (getRange p) p]

			    FunClause _ _ _	-> __IMPOSSIBLE__
			    TypeSig{}		-> __IMPOSSIBLE__
			  where
			    dataOrRec mkDef niceD r x tel t cs = do
                              ds <- niceD fixs cs
                              return $
                                [ NiceDef r [d]
                                  [ Axiom (fuseRange x t) f PublicAccess ConcreteDef Relevant
                                          x (Pi tel t)
                                  ]
                                  -- Setting the range to the range of t makes sense
                                  -- since the only errors you get at the level of the
                                  -- definitions are the type not ending in a sort.
                                  [ mkDef (getRange t) f PublicAccess ConcreteDef x
                                          (concatMap binding tel)
                                          ds
                                  ]
                                ]
                              where
                                f = fixity x fixs
                                binding (TypedBindings _ (Arg h rel b)) =
                                    bind h rel b
                                bind h rel (TBind _ xs _) =
                                    map (DomainFree h rel) xs
                                bind h rel (TNoBind e) =
                                    [ DomainFree h rel $ mkBoundName_ (noName (getRange e)) ]



	-- Translate axioms
        niceAx fixs ds = return $ niceAxioms fixs ds

	niceAxioms :: Map.Map Name Fixity' -> [TypeSignature] -> [NiceDeclaration]
	niceAxioms fixs ds = map (niceAxiom fixs) ds

        niceAxiom :: Map.Map Name Fixity' -> TypeSignature -> NiceDeclaration
        niceAxiom fixs d@(TypeSig rel x t) =
            Axiom (getRange d) (fixity x fixs) PublicAccess ConcreteDef rel x t
        niceAxiom fixs d@(Field x argt) =
            NiceField (getRange d) (fixity x fixs) PublicAccess ConcreteDef x argt
        niceAxiom _ _ = __IMPOSSIBLE__

	toPrim :: NiceDeclaration -> NiceDeclaration
	toPrim (Axiom r f a c rel x t) = PrimitiveFunction r f a c x t
	toPrim _		       = __IMPOSSIBLE__

	-- Create a function definition.
	mkFunDef rel fixs x mt ds0 = do
          cs <- mkClauses x $ expandEllipsis ds0
          return $
	    NiceDef (fuseRange x ds0)
		    (TypeSig rel x t : ds0)
		    [ Axiom (fuseRange x t) f PublicAccess ConcreteDef rel x t ]
		    [ FunDef (getRange ds0) ds0 f PublicAccess ConcreteDef x cs
		    ]
	    where
	      f = fixity x fixs
	      t = case mt of
		    Just t  -> t
		    Nothing -> Underscore (getRange x) Nothing


        expandEllipsis :: [Declaration] -> [Declaration]
        expandEllipsis [] = []
        expandEllipsis (d@(FunClause Ellipsis{} _ _) : ds) =
          d : expandEllipsis ds
        expandEllipsis (d@(FunClause lhs@(LHS p ps _ _) _ _) : ds) =
          d : expand p ps ds
          where
            expand _ _ [] = []
            expand p ps (FunClause (Ellipsis _ ps' eqs []) rhs wh : ds) =
              FunClause (LHS p (ps ++ ps') eqs []) rhs wh : expand p ps ds
            expand p ps (FunClause (Ellipsis _ ps' eqs es) rhs wh : ds) =
              FunClause (LHS p (ps ++ ps') eqs es) rhs wh : expand p (ps ++ ps') ds
            expand p ps (d@(FunClause (LHS _ _ _ []) _ _) : ds) =
              d : expand p ps ds
            expand _ _ (d@(FunClause (LHS p ps _ (_ : _)) _ _) : ds) =
              d : expand p ps ds
            expand _ _ (_ : ds) = __IMPOSSIBLE__
        expandEllipsis (_ : ds) = __IMPOSSIBLE__


        -- Turn function clauses into nice function clauses.
        mkClauses :: Name -> [Declaration] -> Nice [Clause]
        mkClauses _ [] = return []
        mkClauses x (FunClause lhs@(LHS _ _ _ []) rhs wh : cs) =
          (Clause x lhs rhs wh [] :) <$> mkClauses x cs
        mkClauses x (FunClause lhs@(LHS _ ps _ es) rhs wh : cs) = do
          when (null with) $ throwError $ MissingWithClauses x
          wcs <- mkClauses x with
          (Clause x lhs rhs wh wcs :) <$> mkClauses x cs'
          where
            (with, cs') = span subClause cs

            -- A clause is a subclause if the number of with-patterns is
            -- greater or equal to the current number of with-patterns plus the
            -- number of with arguments.
            subClause (FunClause (LHS _ ps' _ _) _ _)      =
              length ps' >= length ps + length es
            subClause (FunClause (Ellipsis _ ps' _ _) _ _) = True
            subClause _                                  = __IMPOSSIBLE__
        mkClauses x (FunClause lhs@Ellipsis{} rhs wh : cs) =
          (Clause x lhs rhs wh [] :) <$> mkClauses x cs   -- Will result in an error later.
        mkClauses _ _ = __IMPOSSIBLE__

	noSingletonRawAppP (RawAppP _ [p]) = noSingletonRawAppP p
	noSingletonRawAppP p		   = p

        isFunClauseOf x (FunClause Ellipsis{} _ _) = True
	isFunClauseOf x (FunClause (LHS p _ _ _) _ _) = case noSingletonRawAppP p of
	    IdentP (QName q)	-> x == q
	    _			-> True
		-- more complicated lhss must come with type signatures, so we just assume
		-- it's part of the current definition
	isFunClauseOf _ _ = False

	-- Make a mutual declaration
	mkMutual :: Range -> [Declaration] -> [NiceDeclaration] -> Nice NiceDeclaration
	mkMutual r cs ds = do
            mapM_ checkMutual ds
            setConcrete cs <$> foldM smash (NiceDef r [] [] []) ds
	  where
            setConcrete cs (NiceDef r _ ts ds)  = NiceDef r cs ts ds
            setConcrete cs d		    = __IMPOSSIBLE__

            isRecord RecDef{} = True
            isRecord _	  = False

            checkMutual nd@(NiceDef _ _ _ ds)
--              | any isRecord ds = throwError $ NotAllowedInMutual nd
              | otherwise       = return ()
            checkMutual d = throwError $ NotAllowedInMutual d

            smash nd@(NiceDef r0 _ ts0 ds0) (NiceDef r1 _ ts1 ds1) =
              return $ NiceDef (fuseRange r0 r1) [] (ts0 ++ ts1) (ds0 ++ ds1)
            smash _ _ = __IMPOSSIBLE__

	-- Make a declaration abstract
	mkAbstract d =
	    case d of
		Axiom r f a _ rel x e		    -> Axiom r f a AbstractDef rel x e
		NiceField r f a _ x e		    -> NiceField r f a AbstractDef x e
		PrimitiveFunction r f a _ x e	    -> PrimitiveFunction r f a AbstractDef x e
		NiceDef r cs ts ds		    -> NiceDef r cs (map mkAbstract ts)
								 (map mkAbstractDef ds)
		NiceModule r a _ x tel ds	    -> NiceModule r a AbstractDef x tel [ Abstract (getRange ds) ds ]
		NiceModuleMacro r a _ x ma op is    -> NiceModuleMacro r a AbstractDef x ma op is
		NicePragma _ _			    -> d
		NiceOpen _ _ _			    -> d
		NiceImport _ _ _ _ _		    -> d

	mkAbstractDef d =
	    case d of
		FunDef r ds f a _ x cs   -> FunDef r ds f a AbstractDef x (map mkAbstractClause cs)
		DataDef r f a _ x ps cs  -> DataDef r f a AbstractDef x ps $ map mkAbstract cs
		RecDef r f a _ x c ps cs -> RecDef r f a AbstractDef x (mkAbstract <$> c) ps $ map mkAbstract cs

	mkAbstractClause (Clause x lhs rhs wh with) =
	    Clause x lhs rhs (mkAbstractWhere wh) (map mkAbstractClause with)

	mkAbstractWhere  NoWhere	 = NoWhere
	mkAbstractWhere (AnyWhere ds)	 = AnyWhere [Abstract (getRange ds) ds]
	mkAbstractWhere (SomeWhere m ds) = SomeWhere m [Abstract (getRange ds) ds]

	-- Make a declaration private
	mkPrivate d =
	    case d of
		Axiom r f _ a rel x e		    -> Axiom r f PrivateAccess a rel x e
		NiceField r f _ a x e		    -> NiceField r f PrivateAccess a x e
		PrimitiveFunction r f _ a x e	    -> PrimitiveFunction r f PrivateAccess a x e
		NiceDef r cs ts ds		    -> NiceDef r cs (map mkPrivate ts)
								    (map mkPrivateDef ds)
		NiceModule r _ a x tel ds	    -> NiceModule r PrivateAccess a x tel ds
		NiceModuleMacro r _ a x ma op is    -> NiceModuleMacro r PrivateAccess a x ma op is
		NicePragma _ _			    -> d
		NiceOpen _ _ _			    -> d
		NiceImport _ _ _ _ _		    -> d

	mkPrivateDef d =
	    case d of
		FunDef r ds f _ a x cs   -> FunDef r ds f PrivateAccess a x (map mkPrivateClause cs)
		DataDef r f _ a x ps cs  -> DataDef r f PrivateAccess a x ps (map mkPrivate cs)
		RecDef r f _ a x c ps cs -> RecDef r f PrivateAccess a x (mkPrivate <$> c) ps cs

	mkPrivateClause (Clause x lhs rhs wh with) =
	    Clause x lhs rhs (mkPrivateWhere wh) (map mkPrivateClause with)

	mkPrivateWhere  NoWhere		= NoWhere
	mkPrivateWhere (AnyWhere ds)	= AnyWhere [Private (getRange ds) ds]
	mkPrivateWhere (SomeWhere m ds) = SomeWhere m [Private (getRange ds) ds]

-- | Add more fixities. Throw an exception for multiple fixity declarations.
plusFixities :: Map.Map Name Fixity' -> Map.Map Name Fixity' -> Nice (Map.Map Name Fixity')
plusFixities m1 m2
    | not (null isect) = throwError $ MultipleFixityDecls isect
    | otherwise = return $ Map.unionWithKey mergeFixites m1 m2
    where mergeFixites name (Fixity' f1 s1) (Fixity' f2 s2) = Fixity' f s
              where f | f1 == noFixity = f2
                      | f2 == noFixity = f1
                      | otherwise = __IMPOSSIBLE__
                    s | s1 == noNotation = s2
                      | s2 == noNotation = s1
                      | otherwise = __IMPOSSIBLE__
 	  isect	= [decls x | (x,compat) <- Map.assocs (Map.intersectionWith compatible m1 m2), not compat]

	  decls x = (x, map (Map.findWithDefault __IMPOSSIBLE__ x) [m1,m2])
				-- cpp doesn't know about primes
          compatible (Fixity' f1 s1) (Fixity' f2 s2) = (f1 == noFixity || f2 == noFixity) &&
                                                       (s1 == noNotation || s2 == noNotation)

-- | Get the fixities from the current block. Doesn't go inside /any/ blocks.
--   The reason for this is that fixity declarations have to appear at the same
--   level (or possibly outside an abstract or mutual block) as its target
--   declaration.
fixities :: [Declaration] -> Nice (Map.Map Name Fixity')
fixities (d:ds) = case d of
  Syntax x syn -> do fs <- fixities ds
                     plusFixities fs (Map.singleton x (Fixity' noFixity syn))
  Infix f xs -> plusFixities (Map.fromList [ (x,Fixity' f noNotation) | x <- xs ]) =<< fixities ds
  _          -> fixities ds
fixities [] = return $ Map.empty

notSoNiceDeclarations :: [NiceDeclaration] -> [Declaration]
notSoNiceDeclarations = concatMap notNice
  where
    notNice (Axiom _ _ _ _ rel x e)               = [TypeSig rel x e]
    notNice (NiceField _ _ _ _ x argt)            = [Field x argt]
    notNice (PrimitiveFunction r _ _ _ x e)       = [Primitive r [TypeSig Relevant x e]]
    notNice (NiceDef _ ds _ _)                    = ds
    notNice (NiceModule r _ _ x tel ds)           = [Module r x tel ds]
    notNice (NiceModuleMacro r _ _ x ma o dir)    = [ModuleMacro r x ma o dir]
    notNice (NiceOpen r x dir)                    = [Open r x dir]
    notNice (NiceImport r x as o dir)             = [Import r x as o dir]
    notNice (NicePragma _ p)                      = [Pragma p]
