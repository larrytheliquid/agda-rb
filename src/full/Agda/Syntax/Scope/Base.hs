{-# LANGUAGE CPP, DeriveDataTypeable, GADTs, ScopedTypeVariables #-}

{-| This module defines the notion of a scope and operations on scopes.
-}
module Agda.Syntax.Scope.Base where

import Control.Applicative
import Data.Generics (Typeable, Data)
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Function

import Agda.Syntax.Position
import Agda.Syntax.Common
import Agda.Syntax.Fixity
import Agda.Syntax.Abstract.Name as A
import Agda.Syntax.Concrete.Name as C
import Agda.Syntax.Concrete
  (ImportDirective(..), UsingOrHiding(..), ImportedName(..), Renaming(..))
import qualified Agda.Utils.Map as Map
import Agda.Utils.Tuple

#include "../../undefined.h"
import Agda.Utils.Impossible

-- * Scope representation

-- | A scope is a named collection of names partitioned into public and private
--   names.
data Scope = Scope
      { scopeName     :: A.ModuleName
      , scopeParents  :: [A.ModuleName]
      , scopePrivate  :: NameSpace
      , scopePublic   :: NameSpace
      , scopeImported :: NameSpace -- ^ public opened names
      , scopeImports  :: Map C.QName A.ModuleName
      }
  deriving (Typeable, Data)

data NameSpaceId = PrivateNS | PublicNS | ImportedNS
  deriving (Typeable, Data, Eq)

localNameSpace :: Access -> NameSpaceId
localNameSpace PublicAccess  = PublicNS
localNameSpace PrivateAccess = PrivateNS

importedNameSpace :: Access -> NameSpaceId
importedNameSpace PublicAccess  = ImportedNS
importedNameSpace PrivateAccess = PrivateNS

scopeNameSpace :: NameSpaceId -> Scope -> NameSpace
scopeNameSpace PublicNS   = scopePublic
scopeNameSpace PrivateNS  = scopePrivate
scopeNameSpace ImportedNS = scopeImported

-- | The complete information about the scope at a particular program point
--   includes the scope stack, the local variables, and the context precedence.
data ScopeInfo = ScopeInfo
      { scopeCurrent    :: A.ModuleName
      , scopeModules    :: Map A.ModuleName Scope
      , scopeLocals	:: LocalVars
      , scopePrecedence :: Precedence
      }
  deriving (Typeable, Data)

-- | Local variables
type LocalVars = [(C.Name, A.Name)]

-- | A @NameSpace@ contains the mappings from concrete names that the user can
--   write to the abstract fully qualified names that the type checker wants to
--   read.
data NameSpace = NameSpace
      { nsNames	  :: NamesInScope
      , nsModules :: ModulesInScope
      }
  deriving (Typeable, Data)

type ThingsInScope a = Map C.Name [a]
type NamesInScope    = ThingsInScope AbstractName
type ModulesInScope  = ThingsInScope AbstractModule

data InScopeTag a where
  NameTag   :: InScopeTag AbstractName
  ModuleTag :: InScopeTag AbstractModule

class Eq a => InScope a where
  inScopeTag :: InScopeTag a

inNameSpace :: forall a. InScope a => NameSpace -> ThingsInScope a
inNameSpace = case inScopeTag :: InScopeTag a of
  NameTag   -> nsNames
  ModuleTag -> nsModules

instance KillRange ScopeInfo where
  killRange m = m

instance InScope AbstractName where
  inScopeTag = NameTag

instance InScope AbstractModule where
  inScopeTag = ModuleTag

-- | We distinguish constructor names from other names.
data KindOfName = ConName | DefName
  deriving (Eq, Show, Typeable, Data)

-- | Apart from the name, we also record whether it's a constructor or not and
--   what the fixity is.
data AbstractName = AbsName
      { anameName   :: A.QName
      , anameKind   :: KindOfName
      }
  deriving (Typeable, Data)

-- | For modules we record the arity. I'm not sure that it's every used anywhere.
data AbstractModule = AbsModule
      { amodName    :: A.ModuleName
      }
  deriving (Typeable, Data)

instance Eq AbstractName where
  (==) = (==) `on` anameName

instance Ord AbstractName where
  compare = compare `on` anameName

instance Eq AbstractModule where
  (==) = (==) `on` amodName

instance Ord AbstractModule where
  compare = compare `on` amodName

instance Show ScopeInfo where
  show (ScopeInfo this mods locals ctx) =
    unlines $
      [ "ScopeInfo"
      , "  current = " ++ show this
      ] ++
      (if null locals then [] else [ "  locals  = " ++ show locals ]) ++
      [ "  context = " ++ show ctx
      , "  modules"
      ] ++ map ("    "++) (relines . map show $ Map.elems mods)
    where
      relines = filter (not . null) . lines . unlines

blockOfLines :: String -> [String] -> [String]
blockOfLines _  [] = []
blockOfLines hd ss = hd : map ("  "++) ss

instance Show Scope where
  show (Scope { scopeName = name, scopeParents = parents, scopeImports = imps
              , scopePublic = pub, scopePrivate = pri, scopeImported = imp }) =
    unlines $
      [ "* scope " ++ show name ] ++ ind (
         blockOfLines "public"   (lines $ show pub)
      ++ blockOfLines "imported" (lines $ show imp)
      ++ blockOfLines "private"  (lines $ show pri)
      ++ blockOfLines "imports"  (case Map.keys imps of
                                    [] -> []
                                    ks -> [ show ks ]
                                 )
      )
    where ind = map ("  " ++)

instance Show NameSpace where
  show (NameSpace names mods) =
    unlines $
      blockOfLines "names"   (map pr $ Map.toList names) ++
      blockOfLines "modules" (map pr $ Map.toList mods)
    where
      pr :: (Show a, Show b) => (a,b) -> String
      pr (x, y) = show x ++ " --> " ++ show y

instance Show AbstractName where
  show = show . anameName

instance Show AbstractModule where
  show = show . amodName

-- * Operations on names

instance HasRange AbstractName where
  getRange = getRange . anameName

instance SetRange AbstractName where
  setRange r x = x { anameName = setRange r $ anameName x }

-- * Operations on name and module maps.

mergeNames :: InScope a => ThingsInScope a -> ThingsInScope a -> ThingsInScope a
mergeNames = Map.unionWith union

-- * Operations on name spaces

-- | The empty name space.
emptyNameSpace :: NameSpace
emptyNameSpace = NameSpace Map.empty Map.empty


-- | Map functions over the names and modules in a name space.
mapNameSpace :: (NamesInScope   -> NamesInScope  ) ->
		(ModulesInScope -> ModulesInScope) ->
		NameSpace -> NameSpace
mapNameSpace fd fm ns =
  ns { nsNames	 = fd $ nsNames ns
     , nsModules = fm $ nsModules  ns
     }

-- | Zip together two name spaces.
zipNameSpace :: (NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
		(ModulesInScope -> ModulesInScope -> ModulesInScope) ->
		NameSpace -> NameSpace -> NameSpace
zipNameSpace fd fm ns1 ns2 =
  ns1 { nsNames	  = nsNames   ns1 `fd` nsNames   ns2
      , nsModules = nsModules ns1 `fm` nsModules ns2
      }

-- | Map monadic function over a namespace.
mapNameSpaceM :: Monad m =>
  (NamesInScope   -> m NamesInScope  ) ->
  (ModulesInScope -> m ModulesInScope) ->
  NameSpace -> m NameSpace
mapNameSpaceM fd fm ns = do
  ds <- fd $ nsNames ns
  ms <- fm $ nsModules ns
  return $ ns { nsNames = ds, nsModules = ms }

-- * General operations on scopes

-- | The empty scope.
emptyScope :: Scope
emptyScope = Scope { scopeName	   = noModuleName
                   , scopeParents  = []
		   , scopePublic   = emptyNameSpace
		   , scopePrivate  = emptyNameSpace
                   , scopeImported = emptyNameSpace
                   , scopeImports  = Map.empty
		   }

-- | The empty scope info.
emptyScopeInfo :: ScopeInfo
emptyScopeInfo = ScopeInfo
		  { scopeCurrent    = noModuleName
                  , scopeModules    = Map.singleton noModuleName emptyScope
		  , scopeLocals	    = []
		  , scopePrecedence = TopCtx
		  }

-- | Map functions over the names and modules in a scope.
mapScope :: (NameSpaceId -> NamesInScope   -> NamesInScope  ) ->
	    (NameSpaceId -> ModulesInScope -> ModulesInScope) ->
	    Scope -> Scope
mapScope fd fm s =
  s { scopePrivate  = mapNS PrivateNS  $ scopePrivate  s
    , scopePublic   = mapNS PublicNS   $ scopePublic   s
    , scopeImported = mapNS ImportedNS $ scopeImported s
    }
  where
    mapNS acc = mapNameSpace (fd acc) (fm acc)

-- | Same as 'mapScope' but applies the same function to all name spaces.
mapScope_ :: (NamesInScope   -> NamesInScope  ) ->
	     (ModulesInScope -> ModulesInScope) ->
	     Scope -> Scope
mapScope_ fd fm = mapScope (const fd) (const fm)

-- | Map monadic functions over the names and modules in a scope.
mapScopeM :: Monad m =>
  (NameSpaceId -> NamesInScope   -> m NamesInScope  ) ->
  (NameSpaceId -> ModulesInScope -> m ModulesInScope) ->
  Scope -> m Scope
mapScopeM fd fm s = do
  pri <- mapNS PrivateNS  $ scopePrivate  s
  pub <- mapNS PublicNS   $ scopePublic   s
  imp <- mapNS ImportedNS $ scopeImported s
  return $ s { scopePrivate = pri, scopePublic = pub, scopeImported = imp }
  where
    mapNS acc = mapNameSpaceM (fd acc) (fm acc)

-- | Same as 'mapScopeM' but applies the same function to both the public and
--   private name spaces.
mapScopeM_ :: Monad m =>
  (NamesInScope   -> m NamesInScope  ) ->
  (ModulesInScope -> m ModulesInScope) ->
  Scope -> m Scope
mapScopeM_ fd fm = mapScopeM (const fd) (const fm)

-- | Zip together two scopes. The resulting scope has the same name as the
--   first scope.
zipScope :: (NameSpaceId -> NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
	    (NameSpaceId -> ModulesInScope -> ModulesInScope -> ModulesInScope) ->
	    Scope -> Scope -> Scope
zipScope fd fm s1 s2 =
  s1 { scopePrivate  = zipNS PrivateNS  (scopePrivate  s1) (scopePrivate  s2)
     , scopePublic   = zipNS PublicNS   (scopePublic   s1) (scopePublic   s2)
     , scopeImported = zipNS ImportedNS (scopeImported s1) (scopeImported s2)
     , scopeImports  = Map.union (scopeImports s1) (scopeImports s2)
     }
  where
    zipNS acc = zipNameSpace (fd acc) (fm acc)

-- | Same as 'zipScope' but applies the same function to both the public and
--   private name spaces.
zipScope_ :: (NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
	     (ModulesInScope -> ModulesInScope -> ModulesInScope) ->
	     Scope -> Scope -> Scope
zipScope_ fd fm = zipScope (const fd) (const fm)

-- | Filter a scope keeping only concrete names matching the predicates.
--   The first predicate is applied to the names and the second to the modules.
filterScope :: (C.Name -> Bool) -> (C.Name -> Bool) -> Scope -> Scope
filterScope pd pm = mapScope_ (Map.filterKeys pd) (Map.filterKeys pm)

-- | Return all names in a scope.
allNamesInScope :: InScope a => Scope -> ThingsInScope a
allNamesInScope = namesInScope [scopePublic, scopeImported, scopePrivate]

-- | Returns the scope's non-private names.
exportedNamesInScope :: InScope a => Scope -> ThingsInScope a
exportedNamesInScope = namesInScope [scopePublic, scopeImported]

namesInScope :: InScope a => [Scope -> NameSpace] -> Scope -> ThingsInScope a
namesInScope fs s =
  foldr1 mergeNames [ inNameSpace (f s) | f <- fs ]

allThingsInScope :: Scope -> NameSpace
allThingsInScope = thingsInScope [scopePublic, scopeImported, scopePrivate]

thingsInScope :: [Scope -> NameSpace] -> Scope -> NameSpace
thingsInScope fs s =
  NameSpace { nsNames   = namesInScope fs s
            , nsModules = namesInScope fs s
            }

-- | Merge two scopes. The result has the name of the first scope.
mergeScope :: Scope -> Scope -> Scope
mergeScope = zipScope_ mergeNames mergeNames

-- | Merge a non-empty list of scopes. The result has the name of the first
--   scope in the list.
mergeScopes :: [Scope] -> Scope
mergeScopes [] = __IMPOSSIBLE__
mergeScopes ss = foldr1 mergeScope ss

-- * Specific operations on scopes

-- | Move all names in a scope to the given name space (except never move from
--   Imported to Public).
setScopeAccess :: NameSpaceId -> Scope -> Scope
setScopeAccess a s = s { scopeImported = ns ImportedNS
		       , scopePrivate  = ns PrivateNS
                       , scopePublic   = ns PublicNS
		       }
  where
    zero  = emptyNameSpace
    one   = allThingsInScope s
    imp   = thingsInScope [scopeImported] s
    noimp = thingsInScope [scopePublic, scopePrivate] s

    ns b = case (a, b) of
      (PublicNS, PublicNS)   -> noimp
      (PublicNS, ImportedNS) -> imp
      _ | a == b             -> one
        | otherwise          -> zero

-- | Add names to a scope.
addNamesToScope :: NameSpaceId -> C.Name -> [AbstractName] -> Scope -> Scope
addNamesToScope acc x ys s = mergeScope s s1
  where
    s1 = setScopeAccess acc $ emptyScope
	 { scopePublic = emptyNameSpace { nsNames = Map.singleton x ys } }

-- | Add a name to a scope.
addNameToScope :: NameSpaceId -> C.Name -> AbstractName -> Scope -> Scope
addNameToScope acc x y s = addNamesToScope acc x [y] s

-- | Add a module to a scope.
addModuleToScope :: NameSpaceId -> C.Name -> AbstractModule -> Scope -> Scope
addModuleToScope acc x m s = mergeScope s s1
  where
    s1 = setScopeAccess acc $ emptyScope
	 { scopePublic = emptyNameSpace { nsModules = Map.singleton x [m] } }

-- | Apply an 'ImportDirective' to a scope.
applyImportDirective :: ImportDirective -> Scope -> Scope
applyImportDirective dir s = mergeScope usedOrHidden renamed
  where
    usedOrHidden = useOrHide (hideLHS (renaming dir) $ usingOrHiding dir) s
    renamed	 = rename (renaming dir) $ useOrHide useRenamedThings s

    useRenamedThings = Using $ map renFrom $ renaming dir

    hideLHS :: [Renaming] -> UsingOrHiding -> UsingOrHiding
    hideLHS _	i@(Using _) = i
    hideLHS ren (Hiding xs) = Hiding $ xs ++ map renFrom ren

    useOrHide :: UsingOrHiding -> Scope -> Scope
    useOrHide (Hiding xs) s = filterNames notElem notElem xs s
    useOrHide (Using  xs) s = filterNames elem	  elem	  xs s

    filterNames :: (C.Name -> [C.Name] -> Bool) -> (C.Name -> [C.Name] -> Bool) ->
		   [ImportedName] -> Scope -> Scope
    filterNames pd pm xs = filterScope' (flip pd ds) (flip pm ms)
      where
	ds = [ x | ImportedName   x <- xs ]
	ms = [ m | ImportedModule m <- xs ]

    filterScope' pd pm = filterScope pd pm

    -- Renaming
    rename :: [Renaming] -> Scope -> Scope
    rename rho = mapScope_ (Map.mapKeys $ ren drho)
			   (Map.mapKeys $ ren mrho)
      where
	mrho = [ (x, y) | Renaming { renFrom = ImportedModule x, renTo = y } <- rho ]
	drho = [ (x, y) | Renaming { renFrom = ImportedName   x, renTo = y } <- rho ]

	ren r x = maybe x id $ lookup x r

-- | Rename the abstract names in a scope.
renameCanonicalNames :: Map A.QName A.QName -> Map A.ModuleName A.ModuleName ->
			Scope -> Scope
renameCanonicalNames renD renM = mapScope_ renameD renameM
  where
    renameD = Map.map (map $ onName  rD)
    renameM = Map.map (map $ onMName rM)

    onName  f x = x { anameName = f $ anameName x }
    onMName f x = x { amodName  = f $ amodName  x }

    rD x = maybe x id $ Map.lookup x renD
    rM x = maybe x id $ Map.lookup x renM

-- | Restrict the private name space of a scope
restrictPrivate :: Scope -> Scope
restrictPrivate s = s { scopePrivate = emptyNameSpace, scopeImports = Map.empty }

-- | Get the public parts of the public modules of a scope
publicModules :: ScopeInfo -> Map A.ModuleName Scope
publicModules scope = Map.filterWithKey (\m _ -> reachable m) allMods
  where
    allMods   = Map.map restrictPrivate $ scopeModules scope
    root      = scopeCurrent scope
    modules s = map amodName $ concat $ Map.elems $ allNamesInScope s

    chase m = m : case Map.lookup m allMods of
      Just s  -> concatMap chase $ modules s
      Nothing -> __IMPOSSIBLE__

    reachable = (`elem` chase root)

everythingInScope :: ScopeInfo -> NameSpace
everythingInScope scope =
    allThingsInScope
    $ mergeScopes
    [ s | (m, s) <- Map.toList (scopeModules scope), m `elem` current ]
  where
    this    = scopeCurrent scope
    parents = case Map.lookup this (scopeModules scope) of
      Just s  -> scopeParents s
      Nothing -> __IMPOSSIBLE__
    current = this : parents

-- | Look up a name in the scope
scopeLookup :: forall a. InScope a => C.QName -> ScopeInfo -> [a]
scopeLookup q scope = nub $ findName q root ++ imports
  where
    this    :: A.ModuleName
    this    = scopeCurrent scope

    current :: Scope
    current = moduleScope this

    root    :: Scope
    root    = mergeScopes $ current : map moduleScope (scopeParents current)

    tag = inScopeTag :: InScopeTag a

    splitName :: C.QName -> [(C.QName, C.QName)]
    splitName (C.QName x) = []
    splitName (C.Qual x q) = (C.QName x, q) : do
      (m, r) <- splitName q
      return (C.Qual x m, r)

    imported :: C.QName -> [A.ModuleName]
    imported q = maybe [] (:[]) $ Map.lookup q $ scopeImports root

    topImports :: [a]
    topImports = case tag of
      NameTag   -> []
      ModuleTag -> map AbsModule (imported q)

    imports :: [a]
    imports = topImports ++ do
      (m, x) <- splitName q
      m <- imported m
      x <- findName x (restrictPrivate $ moduleScope m)
      return x

    moduleScope :: A.ModuleName -> Scope
    moduleScope name = case Map.lookup name (scopeModules scope) of
      Nothing -> __IMPOSSIBLE__
      Just s  -> s

    lookupName :: forall a. InScope a => C.Name -> Scope -> [a]
    lookupName x s = maybe [] id $ Map.lookup x (allNamesInScope s)

    findName :: forall a. InScope a => C.QName -> Scope -> [a]
    findName (C.QName x)  s = lookupName x s
    findName (C.Qual x q) s = do
        m <- nub $ mods ++ defs -- record types will appear bot as a mod and a def
        Just s' <- return $ Map.lookup m (scopeModules scope)
        findName q (restrictPrivate s')
      where
        mods, defs :: [ModuleName]
        mods = amodName <$> lookupName x s
        -- Qualified constructors are qualified by their datatype rather than a module
        defs = mnameFromList . qnameToList . anameName <$> lookupName x s

-- * Inverse look-up

-- | Find the shortest concrete name that maps (uniquely) to a given abstract
--   name.
inverseScopeLookup :: Either A.ModuleName A.QName -> ScopeInfo -> Maybe C.QName
inverseScopeLookup name scope = case name of
  Left  m -> best $ filter unambiguousModule $ findModule m
  Right q -> best $ filter unambiguousName   $ findName nameMap q
  where
    this = scopeCurrent scope
    current = this : scopeParents (moduleScope this)
    scopes  = [ (m, restrict m s) | (m, s) <- Map.toList (scopeModules scope) ]

    moduleScope name = case Map.lookup name (scopeModules scope) of
      Nothing -> __IMPOSSIBLE__
      Just s  -> s

    restrict m s | m `elem` current = s
                 | otherwise = restrictPrivate s

    len :: C.QName -> Int
    len (C.QName _)  = 1
    len (C.Qual _ x) = 1 + len x

    best xs = case sortBy (compare `on` len) xs of
      []    -> Nothing
      x : _ -> Just x

    unique :: forall a . [a] -> Bool
    unique []      = __IMPOSSIBLE__
    unique [_]     = True
    unique (_:_:_) = False

    unambiguousModule q = unique (scopeLookup q scope :: [AbstractModule])
    unambiguousName   q = unique xs || all ((ConName ==) . anameKind) xs
      where xs = scopeLookup q scope

    findName :: Ord a => Map a [(A.ModuleName, C.Name)] -> a -> [C.QName]
    findName table q = do
      (m, x) <- maybe [] id $ Map.lookup q table
      if m `elem` current
        then return (C.QName x)
        else do
          y <- findModule m
          return $ C.qualify y x

    findModule :: A.ModuleName -> [C.QName]
    findModule q = findName moduleMap q ++
                   maybe [] id (Map.lookup q importMap)

    importMap = Map.unionsWith (++) $ do
      (m, s) <- scopes
      (x, y) <- Map.toList $ scopeImports s
      return $ Map.singleton y [x]

    moduleMap = Map.unionsWith (++) $ do
      (m, s)  <- scopes
      (x, ms) <- Map.toList (allNamesInScope s)
      q       <- amodName <$> ms
      return $ Map.singleton q [(m, x)]

    nameMap = Map.unionsWith (++) $ do
      (m, s)  <- scopes
      (x, ms) <- Map.toList (allNamesInScope s)
      q       <- anameName <$> ms
      return $ Map.singleton q [(m, x)]

-- | Takes the first component of 'inverseScopeLookup'.
inverseScopeLookupName :: A.QName -> ScopeInfo -> Maybe C.QName
inverseScopeLookupName x = inverseScopeLookup (Right x)

-- | Takes the second component of 'inverseScopeLookup'.
inverseScopeLookupModule :: A.ModuleName -> ScopeInfo -> Maybe C.QName
inverseScopeLookupModule x = inverseScopeLookup (Left x)
