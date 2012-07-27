-- |
-- Copyright   : (c) 2011 Simon Meier
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : portable
--
-- General support for pretty printing theories.
module Theory.Text.Pretty (
  -- * General highlighters
    module Text.PrettyPrint.Highlight

  -- * Additional combinators
  , vsep
  , fsepList
  , fsepSet

  -- * Comments
  , lineComment
  , multiComment

  , lineComment_
  , multiComment_

  -- * Keywords
  , kwTheoryHeader
  , kwEnd
  , kwModulo
  , kwBy
  , kwCase
  , kwNext
  , kwQED
  , kwLemma
  , kwAxiom

  -- ** Composed forms
  , kwRuleModulo
  , kwInstanceModulo
  , kwVariantsModulo
  , kwTypesModulo

  -- * Operators
  , opProvides
  , opRequires
  , opAction
  , opPath
  , opLess
  , opEqual
  , opDedBefore
  , opEdge

  ) where

import qualified Data.Set                   as S

import           Text.PrettyPrint.Highlight


------------------------------------------------------------------------------
-- Additional combinators
------------------------------------------------------------------------------

-- | Vertically separate a list of documents by empty lines.
vsep :: Document d => [d] -> d
vsep = foldr ($--$) emptyDoc

-- | Pretty print a list of values as a comma-separated list wrapped in
-- paragraph mode.
fsepList :: Document d => (a -> d) -> [a] -> d
fsepList pp = fsep . punctuate comma . map pp

-- | Pretty print a set of values as a comma-separated list wrapped in
-- paragraph mode.
fsepSet :: Document d => (a -> d) -> S.Set a -> d
fsepSet pp = fsep . punctuate comma . map pp . S.toList


------------------------------------------------------------------------------
-- Comments
------------------------------------------------------------------------------

lineComment :: HighlightDocument d => d -> d
lineComment d = comment $ text "//" <-> d

lineComment_ :: HighlightDocument d => String -> d
lineComment_ = lineComment . text

multiComment :: HighlightDocument d => d -> d
multiComment d = comment $ fsep [text "/*", d, text "*/"]

multiComment_ :: HighlightDocument d => [String] -> d
multiComment_ ls = comment $ fsep [text "/*", vcat $ map text ls, text "*/"]

------------------------------------------------------------------------------
-- Keywords
------------------------------------------------------------------------------

kwTheoryHeader :: HighlightDocument d => d -> d
kwTheoryHeader name = keyword_ "theory" <-> name <-> keyword_ "begin"

kwEnd, kwBy, kwCase, kwNext, kwQED, kwAxiom, kwLemma :: HighlightDocument d => d
kwEnd   = keyword_ "end"
kwBy    = keyword_ "by"
kwCase  = keyword_ "case"
kwNext  = keyword_ "next"
kwQED   = keyword_ "qed"
kwAxiom = keyword_ "axiom"
kwLemma = keyword_ "lemma"

kwModulo :: HighlightDocument d
         => String  -- ^ What
         -> String  -- ^ modulo theory
         -> d
kwModulo what thy = keyword_ what <-> parens (keyword_ "modulo" <-> text thy)

kwRuleModulo, kwInstanceModulo, kwTypesModulo, kwVariantsModulo
  :: HighlightDocument d => String -> d
kwRuleModulo     = kwModulo "rule"
kwInstanceModulo = kwModulo "instance"
kwTypesModulo    = kwModulo "type assertions"
kwVariantsModulo = kwModulo "variants"


------------------------------------------------------------------------------
-- Operators
------------------------------------------------------------------------------

opProvides, opRequires, opAction, opPath, opLess, opEqual, opDedBefore, opEdge
  :: HighlightDocument d => d
opProvides  = operator_ ":>"
opRequires  = operator_ "<:"
opAction    = operator_ "@"
opPath      = operator_ ">+>"
opLess      = operator_ "<"
opEqual     = operator_ "="
opDedBefore = operator_ "--|"
opEdge      = operator_ ">->"

