------------------------------------------------------------------------
-- Universe levels
------------------------------------------------------------------------

module Common.Level where

postulate
  Level : Set
  lzero : Level
  lsuc  : (i : Level) → Level
  _⊔_   : Level -> Level -> Level

{-# IMPORT Common.FFI #-}
{-# COMPILED_TYPE Level Common.FFI.Level #-}
{-# COMPILED lzero Common.FFI.Zero #-}
{-# COMPILED lsuc Common.FFI.Suc #-}

{-# BUILTIN LEVEL     Level #-}
{-# BUILTIN LEVELZERO lzero  #-}
{-# BUILTIN LEVELSUC  lsuc   #-}
{-# BUILTIN LEVELMAX  _⊔_ #-}

infixl 6 _⊔_


