{-# LANGUAGE CPP, DeriveDataTypeable #-}

{-| Names in the concrete syntax are just strings (or lists of strings for
    qualified names).
-}
module Agda.Syntax.Concrete.Name where

import Control.Applicative

import Data.List
import Data.Maybe
import Data.Generics (Typeable, Data)

import System.FilePath

import Test.QuickCheck

import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Utils.FileName
import Agda.Utils.Pretty

#include "../../undefined.h"
import Agda.Utils.Impossible

{-| A name is a non-empty list of alternating 'Id's and 'Hole's. A normal name
    is represented by a singleton list, and operators are represented by a list
    with 'Hole's where the arguments should go. For instance: @[Hole,Id "+",Hole]@
    is infix addition.

    Equality and ordering on @Name@s are defined to ignore range so same names
    in different locations are equal.
-}
data Name = Name !Range [NamePart]
	  | NoName !Range NameId
    deriving (Typeable, Data)

data NamePart = Hole | Id String
    deriving (Typeable, Data)

-- | @noName_ = 'noName' 'noRange'@
noName_ :: Name
noName_ = noName noRange

-- | @noName r = 'Name' r ['Hole']@
noName :: Range -> Name
noName r = NoName r (NameId 0 0)

isNoName :: Name -> Bool
isNoName (NoName _ _)    = True
isNoName (Name _ [Hole]) = True   -- TODO: Track down where these come from
isNoName _               = False

-- | Is the name an operator?

isOperator :: Name -> Bool
isOperator (NoName {}) = False
isOperator (Name _ ps) = length ps > 1

nameParts :: Name -> [NamePart]
nameParts (Name _ ps)  = ps
nameParts (NoName _ _) = [Hole]

-- | @qualify A.B x == A.B.x@
qualify :: QName -> Name -> QName
qualify (QName m) x	= Qual m (QName x)
qualify (Qual m m') x	= Qual m $ qualify m' x

-- | @unqualify A.B.x == x@
--
-- The range is preserved.
unqualify :: QName -> Name
unqualify q = unqualify' q `withRangeOf` q
  where
  unqualify' (QName x)  = x
  unqualify' (Qual _ x) = unqualify' x

-- | @qnameParts A.B.x = [A, B, x]@
qnameParts :: QName -> [Name]
qnameParts (Qual x q) = x : qnameParts q
qnameParts (QName x)  = [x]

-- Define equality on @Name@ to ignore range so same names in different
--     locations are equal.
--
--   Is there a reason not to do this? -Jeff
--
--   No. But there are tons of reasons to do it. For instance, when using
--   names as keys in maps you really don't want to have to get the range
--   right to be able to do a lookup. -Ulf

instance Eq Name where
    Name _ xs  == Name _ ys  = xs == ys
    NoName _ i == NoName _ j = i == j
    _	       == _	     = False

instance Ord Name where
    compare (Name _ xs)  (Name _ ys)  = compare xs ys
    compare (NoName _ i) (NoName _ j) = compare i j
    compare (NoName {})  (Name {})    = LT
    compare (Name {})    (NoName {})  = GT

instance Eq NamePart where
  Hole  == Hole  = True
  Id s1 == Id s2 = s1 == s2
  _     == _     = False

instance Ord NamePart where
  compare Hole    Hole    = EQ
  compare Hole    (Id {}) = LT
  compare (Id {}) Hole    = GT
  compare (Id s1) (Id s2) = compare s1 s2

-- | @QName@ is a list of namespaces and the name of the constant.
--   For the moment assumes namespaces are just @Name@s and not
--     explicitly applied modules.
--   Also assumes namespaces are generative by just using derived
--     equality. We will have to define an equality instance to
--     non-generative namespaces (as well as having some sort of
--     lookup table for namespace names).
data QName = Qual  Name QName
           | QName Name
  deriving (Typeable, Data, Eq, Ord)

-- | Top-level module names.
--
-- Invariant: The list must not be empty.

newtype TopLevelModuleName
  = TopLevelModuleName { moduleNameParts :: [String] }
  deriving (Show, Eq, Ord, Typeable, Data)

-- | Turns a qualified name into a 'TopLevelModuleName'. The qualified
-- name is assumed to represent a top-level module name.

toTopLevelModuleName :: QName -> TopLevelModuleName
toTopLevelModuleName = TopLevelModuleName . map show . qnameParts

-- | Turns a top-level module name into a file name with the given
-- suffix.

moduleNameToFileName :: TopLevelModuleName -> String -> FilePath
moduleNameToFileName (TopLevelModuleName []) ext = __IMPOSSIBLE__
moduleNameToFileName (TopLevelModuleName ms) ext =
  joinPath (init ms) </> last ms <.> ext

-- | Finds the current project's \"root\" directory, given a project
-- file and the corresponding top-level module name.
--
-- Example: If the module \"A.B.C\" is located in the file
-- \"/foo/A/B/C.agda\", then the root is \"/foo/\".
--
-- Precondition: The module name must be well-formed.

projectRoot :: AbsolutePath -> TopLevelModuleName -> AbsolutePath
projectRoot file (TopLevelModuleName m) =
  mkAbsolute $
  foldr (.) id (replicate (length m - 1) takeDirectory) $
  takeDirectory $
  filePath file

isHole :: NamePart -> Bool
isHole Hole = True
isHole _    = False

isPrefix, isPostfix, isInfix, isNonfix :: Name -> Bool
isPrefix  x = not (isHole (head xs)) &&      isHole (last xs)  where xs = nameParts x
isPostfix x =      isHole (head xs)  && not (isHole (last xs)) where xs = nameParts x
isInfix   x =      isHole (head xs)  &&      isHole (last xs)  where xs = nameParts x
isNonfix  x = not (isHole (head xs)) && not (isHole (last xs)) where xs = nameParts x

instance Show Name where
    show (Name _ xs)  = concatMap show xs
    show (NoName _ _) = "_"

instance Show NamePart where
    show Hole   = "_"
    show (Id s) = s

instance Show QName where
    show (Qual m x) = show m ++ "." ++ show x
    show (QName x)  = show x

instance Pretty TopLevelModuleName where
  pretty (TopLevelModuleName ms) = text $ intercalate "." ms

instance Arbitrary TopLevelModuleName where
  arbitrary = TopLevelModuleName <$> listOf1 (listOf1 $ elements "AB")

instance CoArbitrary TopLevelModuleName where
  coarbitrary (TopLevelModuleName m) = coarbitrary m

instance HasRange Name where
    getRange (Name r ps)  = r
    getRange (NoName r _) = r

instance HasRange QName where
    getRange (QName  x) = getRange x
    getRange (Qual n x)	= fuseRange n x

instance SetRange Name where
  setRange r (Name _ ps)  = Name r ps
  setRange r (NoName _ i) = NoName r i

instance KillRange QName where
  killRange (QName x) = QName $ killRange x
  killRange (Qual n x) = killRange n `Qual` killRange x

instance KillRange Name where
  killRange (Name r ps)  = Name (killRange r) ps
  killRange (NoName r i) = NoName (killRange r) i
