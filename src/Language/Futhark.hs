-- | Re-export the external Futhark modules for convenience.
module Language.Futhark
  ( module Language.Futhark.Syntax
  , module Language.Futhark.Attributes
  , module Language.Futhark.Pretty

  , Ident, DimIndex, Exp, Pattern
  , ModExp, ModParam, SigExp, ModBind, SigBind
  , ValBind, Dec, Spec, Prog
  , TypeBind, TypeDecl
  , StructTypeArg, ArrayElemType
  , TypeParam, Case
  )
  where

import Language.Futhark.Syntax
import Language.Futhark.Attributes
import Language.Futhark.Pretty

-- | An identifier with type- and aliasing information.
type Ident = IdentBase Info VName

-- | An index with type information.
type DimIndex = DimIndexBase Info VName

-- | An expression with type information.
type Exp = ExpBase Info VName

-- | A pattern with type information.
type Pattern = PatternBase Info VName

-- | An constant declaration with type information.
type ValBind = ValBindBase Info VName

-- | A type declaration with type information
type TypeDecl = TypeDeclBase Info VName

-- | A type binding with type information.
type TypeBind = TypeBindBase Info VName

-- | A type-checked module binding.
type ModBind = ModBindBase Info VName

-- | A type-checked module type binding.
type SigBind = SigBindBase Info VName

-- | A type-checked module expression.
type ModExp = ModExpBase Info VName

-- | A type-checked module parameter.
type ModParam = ModParamBase Info VName

-- | A type-checked module type expression.
type SigExp = SigExpBase Info VName

-- | A type-checked declaration.
type Dec = DecBase Info VName

-- | A type-checked specification.
type Spec = SpecBase Info VName

-- | An Futhark program with type information.
type Prog = ProgBase Info VName

-- | A known type arg with shape annotations.
type StructTypeArg = TypeArg (DimDecl VName)

-- | A type-checked type parameter.
type TypeParam = TypeParamBase VName

-- | A known array element type with no shape annotations.
type ArrayElemType = ArrayElemTypeBase ()

-- | A type-checked case (of a match expression).
type Case = CaseBase Info VName
