{-# LANGUAGE AllowAmbiguousTypes, ConstraintKinds, DefaultSignatures, DeriveDataTypeable, DeriveFunctor,
             FlexibleContexts, OverloadedStrings, RankNTypes, ScopedTypeVariables, TypeApplications, TypeFamilies,
             UndecidableInstances #-}
module Text.Grampa.Class (MultiParsing(..), GrammarParsing(..), AmbiguousParsing(..), InputParsing(..),
                          InputCharParsing(..), Lexical(..), ParseResults, ParseFailure(..), Expected(..),
                          Ambiguous(..), Position, positionOffset, completeParser) where

import Control.Applicative (Alternative(empty), liftA2, (<|>))
import Data.Char (isAlphaNum, isLetter, isSpace)
import Data.Functor (void)
import Data.Functor.Classes (Show1(..))
import Data.Functor.Compose (Compose(..))
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Data (Data)
import Data.Typeable (Typeable)
import Data.Monoid (Monoid(mempty, mappend))
import qualified Data.Monoid.Null as Null
import Data.Monoid.Null (MonoidNull)
import qualified Data.Monoid.Factorial as Factorial
import Data.Monoid.Factorial (FactorialMonoid)
import Data.Monoid.Textual (TextualMonoid)
import Data.Semigroup (Semigroup((<>)))
import Text.Parser.Combinators (Parsing((<?>), eof, try), skipMany)
import Text.Parser.Char (CharParsing)
import qualified Text.Parser.Char
import GHC.Exts (Constraint)

import qualified Rank2

import Prelude hiding (takeWhile)

type ParseResults s = Either (ParseFailure s)

-- | A 'ParseFailure' contains the offset of the parse failure and the list of things expected at that offset.
data ParseFailure s = ParseFailure Int [Expected s] deriving (Eq, Show)
data Expected s = Expected String
                | ExpectedInput s
                deriving (Functor, Eq, Ord, Read, Show)

-- | Opaque data type that represents an input position.
newtype Position s = Position{
  -- | The length of the input from the position to end.
  remainderLength :: Int}

-- | Map the position into its offset from the beginning of the full input.
positionOffset :: FactorialMonoid s => s -> Position s -> Int
positionOffset wholeInput = (wholeLength -) . remainderLength
   where wholeLength = Factorial.length wholeInput
{-# INLINE positionOffset #-}

-- | An 'Ambiguous' parse result, produced by the 'ambiguous' combinator, contains a 'NonEmpty' list of
-- alternative results.
newtype Ambiguous a = Ambiguous (NonEmpty a) deriving (Data, Eq, Ord, Show, Typeable)

instance Show1 Ambiguous where
   liftShowsPrec sp sl d (Ambiguous (h :| l)) t
      | d > 5 = "(Ambiguous $ " <> sp 0 h (" :| " <> sl l (')' : t))
      | otherwise = "Ambiguous (" <> sp 0 h (" :| " <> sl l (')' : t))

instance Functor Ambiguous where
   fmap f (Ambiguous a) = Ambiguous (fmap f a)

instance Applicative Ambiguous where
   pure a = Ambiguous (pure a)
   Ambiguous f <*> Ambiguous a = Ambiguous (f <*> a)

instance Foldable Ambiguous where
   foldMap f (Ambiguous a) = foldMap f a

instance Traversable Ambiguous where
   traverse f (Ambiguous a) = Ambiguous <$> traverse f a

instance Semigroup a => Semigroup (Ambiguous a) where
   Ambiguous xs <> Ambiguous ys = Ambiguous (liftA2 (<>) xs ys)

instance Monoid a => Monoid (Ambiguous a) where
   mempty = Ambiguous (mempty :| [])
   Ambiguous xs `mappend` Ambiguous ys = Ambiguous (liftA2 mappend xs ys)

completeParser :: MonoidNull s => Compose (ParseResults s) (Compose [] ((,) s)) r -> Compose (ParseResults s) [] r
completeParser (Compose (Left failure)) = Compose (Left failure)
completeParser (Compose (Right (Compose results))) =
   case filter (Null.null . fst) results
   of [] -> Compose (Left $ ParseFailure 0 [Expected "complete parse"])
      completeResults -> Compose (Right $ snd <$> completeResults)

-- | Choose one of the instances of this class to parse with.
class MultiParsing m where
   -- | Some parser types produce a single result, others a list of results.
   type ResultFunctor m s :: * -> *
   type GrammarConstraint m (g :: (* -> *) -> *) :: Constraint
   type GrammarConstraint m g = Rank2.Functor g
   -- | Given a rank-2 record of parsers and input, produce a record of parses of the complete input.
   parseComplete :: (GrammarConstraint m g, Eq s, FactorialMonoid s) => g (m g s) -> s -> g (ResultFunctor m s)
   -- | Given a rank-2 record of parsers and input, produce a record of prefix parses paired with the remaining input
   -- suffix.
   parsePrefix :: (GrammarConstraint m g, Eq s, FactorialMonoid s) =>
                  g (m g s) -> s -> g (Compose (ResultFunctor m s) ((,) s))

-- | Parsers that belong to this class can memoize the parse results to avoid exponential performance complexity.
class MultiParsing m => GrammarParsing m where
   type GrammarFunctor m :: ((* -> *) -> *) -> * -> * -> *
   -- | Used to reference a grammar production, only necessary from outside the grammar itself
   nonTerminal :: GrammarConstraint m g => (g (GrammarFunctor m g s) -> GrammarFunctor m g s a) -> m g s a
   -- | Construct a grammar whose every production refers to itself.
   selfReferring :: (GrammarConstraint m g, Rank2.Distributive g) => g (m g s)
   -- | Convert a self-referring grammar function to a grammar.
   fixGrammar :: forall g s. (GrammarConstraint m g, Rank2.Distributive g) => (g (m g s) -> g (m g s)) -> g (m g s)
   -- | Mark a parser that relies on primitive recursion to prevent an infinite loop in 'fixGrammar'.
   recursive :: m g s a -> m g s a

   selfReferring = Rank2.cotraverse nonTerminal id
   {-# INLINE selfReferring #-}
   fixGrammar = ($ selfReferring)
   {-# INLINE fixGrammar #-}
   recursive = id

{-# DEPRECATED endOfInput "Use 'Text.Parser.Combinators.eof' instead" #-}
-- | Methods for parsing monoidal inputs
class Parsing m => InputParsing m where
   type ParserInput m
   -- | A parser that fails on any input and succeeds at its end.
   endOfInput :: m ()
   -- | Always sucessful parser that returns the remaining input without consuming it.
   getInput :: m (ParserInput m)
   -- | Retrieve the 'Position' the parser has reached in the input source.
   getSourcePos :: m (Position (ParserInput m))

   -- | A parser that accepts any single input atom.
   anyToken :: m (ParserInput m)
   -- | A parser that accepts an input atom only if it satisfies the given predicate.
   satisfy :: ((ParserInput m) -> Bool) -> m (ParserInput m)
   -- | A parser that succeeds exactly when satisfy doesn't, equivalent to
   -- 'Text.Parser.Combinators.notFollowedBy' @. satisfy@
   notSatisfy :: (ParserInput m -> Bool) -> m ()

   -- | A stateful scanner. The predicate modifies a state argument, and each transformed state is passed to successive
   -- invocations of the predicate on each token of the input until one returns 'Nothing' or the input ends.
   --
   -- This parser does not fail.  It will return an empty string if the predicate returns 'Nothing' on the first
   -- character.
   --
   -- /Note/: Because this parser does not fail, do not use it with combinators such as 'many', because such parsers
   -- loop until a failure occurs.  Careless use will thus result in an infinite loop.
   scan :: state -> (state -> ParserInput m -> Maybe state) -> m (ParserInput m)
   -- | A parser that consumes and returns the given prefix of the input.
   string :: ParserInput m -> m (ParserInput m)

   -- | A parser accepting the longest sequence of input atoms that match the given predicate; an optimized version of
   -- 'concatMany . satisfy'.
   --
   -- /Note/: Because this parser does not fail, do not use it with combinators such as 'many', because such parsers
   -- loop until a failure occurs.  Careless use will thus result in an infinite loop.
   takeWhile :: (ParserInput m -> Bool) -> m (ParserInput m)
   -- | A parser accepting the longest non-empty sequence of input atoms that match the given predicate; an optimized
   -- version of 'concatSome . satisfy'.
   takeWhile1 :: (ParserInput m -> Bool) -> m (ParserInput m)
   -- | Zero or more argument occurrences like 'many', with concatenated monoidal results.
   concatMany :: Monoid a => m a -> m a

   endOfInput = eof
   notSatisfy predicate = try (void $ satisfy $ not . predicate) <|> eof
   default concatMany :: (Monoid a, Alternative m) => m a -> m a
   concatMany p = go
      where go = mappend <$> try p <*> go <|> pure mempty
   default getSourcePos :: (FactorialMonoid (ParserInput m), Functor m) => m (Position (ParserInput m))
   getSourcePos = Position . Factorial.length <$> getInput
   default scan :: (Monad m, FactorialMonoid (ParserInput m)) =>
                   state -> (state -> ParserInput m -> Maybe state) -> m (ParserInput m)
   scan state f = do i <- getInput
                     let (prefix, _suffix, _state) = Factorial.spanMaybe' state f i
                     string prefix
   default takeWhile :: (Monad m, FactorialMonoid (ParserInput m)) => (ParserInput m -> Bool) -> m (ParserInput m)
   takeWhile predicate = do i <- getInput
                            string (Factorial.takeWhile predicate i)
   default takeWhile1 :: (Monad m, MonoidNull (ParserInput m)) => (ParserInput m -> Bool) -> m (ParserInput m)
   takeWhile1 predicate = do x <- takeWhile predicate
                             if Null.null x then fail "takeWhile1" else pure x
   {-# INLINE concatMany #-}
   {-# INLINE getSourcePos #-}

{-# DEPRECATED satisfyChar "Use 'Text.Parser.Char.satisfy' instead" #-}
-- | Methods for parsing monoidal inputs
class (CharParsing m, InputParsing m) => InputCharParsing m where
   -- | Specialization of 'satisfy' on 'TextualMonoid' inputs, accepting and returning an input character only if it
   -- satisfies the given predicate.
   satisfyChar :: (Char -> Bool) -> m Char
   -- | Specialization of 'satisfy' on 'TextualMonoid' inputs, accepting an input character only if it satisfies the
   -- given predicate, and returning the input atom that represents the character. A faster version of @singleton <$>
   -- satisfyChar p@ and of @satisfy (fromMaybe False p . characterPrefix)@.
   satisfyCharInput :: (Char -> Bool) -> m (ParserInput m)
   -- | A parser that succeeds exactly when satisfy doesn't, equivalent to
   -- 'Text.Parser.Combinators.notFollowedBy' @. satisfy@
   notSatisfyChar :: (Char -> Bool) -> m ()

   -- | Stateful scanner like `scan`, but specialized for 'TextualMonoid' inputs.
   scanChars :: state -> (state -> Char -> Maybe state) -> m (ParserInput m)

   -- | Specialization of 'takeWhile' on 'TextualMonoid' inputs, accepting the longest sequence of input characters that
   -- match the given predicate; an optimized version of @fmap fromString  . many . char@.
   --
   -- /Note/: Because this parser does not fail, do not use it with combinators such as 'many', because such parsers
   -- loop until a failure occurs.  Careless use will thus result in an infinite loop.
   takeCharsWhile :: (Char -> Bool) -> m (ParserInput m)
   -- | Specialization of 'takeWhile1' on 'TextualMonoid' inputs, accepting the longest sequence of input characters
   -- that match the given predicate; an optimized version of @fmap fromString  . some . char@.
   takeCharsWhile1 :: (Char -> Bool) -> m (ParserInput m)

   satisfyChar = Text.Parser.Char.satisfy

-- | Parsers that can produce alternative parses and collect them into an 'Ambiguous' node
class AmbiguousParsing m where
   -- | Collect all alternative parses of the same length into a 'NonEmpty' list of results.
   ambiguous :: m a -> m (Ambiguous a)

-- | If a grammar is 'Lexical', its parsers can instantiate the 'Text.Parser.Token.TokenParsing' class.
class Lexical (g :: (* -> *) -> *) where
   type LexicalConstraint (m :: ((* -> *) -> *) -> * -> * -> *) g s :: Constraint
   -- | Always succeeds, consuming all white space and comments
   lexicalWhiteSpace :: LexicalConstraint m g s => m g s ()
   -- | Consumes all whitespace and comments, failing if there are none
   someLexicalSpace :: LexicalConstraint m g s => m g s ()
   -- | Consumes a single comment, defaults to 'empty'
   lexicalComment :: LexicalConstraint m g s => m g s ()
   -- | Consumes a single semicolon and any trailing whitespace, returning the character |';'|. The method can be
   -- overridden for automatic semicolon insertion, but if it succeeds on semicolon or white space input it must
   -- consume it.
   lexicalSemicolon :: LexicalConstraint m g s => m g s Char
   -- | Applies the argument parser and consumes the trailing 'lexicalWhitespace'
   lexicalToken :: LexicalConstraint m g s => m g s a -> m g s a
   -- | Applies the argument parser, determines whether its result is a legal identifier, and consumes the trailing
   -- 'lexicalWhitespace'
   identifierToken :: LexicalConstraint m g s => m g s s -> m g s s
   -- | Determines whether the given character can start an identifier token, allows only a letter or underscore by
   -- default
   isIdentifierStartChar :: Char -> Bool
   -- | Determines whether the given character can be any part of an identifier token, also allows numbers
   isIdentifierFollowChar :: Char -> Bool
   -- | Parses a valid identifier and consumes the trailing 'lexicalWhitespace'
   identifier :: LexicalConstraint m g s => m g s s
   -- | Parses the argument word whole, not followed by any identifier character, and consumes the trailing
   -- 'lexicalWhitespace'
   keyword :: LexicalConstraint m g s => s -> m g s ()

   type instance LexicalConstraint m g s = (s ~ ParserInput (m g s), Applicative (m g ()), Monad (m g s),
                                            InputCharParsing (m g s), Show s, TextualMonoid s)
   default lexicalComment :: Alternative (m g s) => m g s ()
   default lexicalWhiteSpace :: (LexicalConstraint m g s, InputCharParsing (m g s),
                                 ParserInput (m g s) ~ s, TextualMonoid s)
                             => m g s ()
   default someLexicalSpace :: (LexicalConstraint m g s, InputCharParsing (m g s), ParserInput (m g s) ~ s,
                                TextualMonoid s)
                            => m g s ()
   default lexicalSemicolon :: (LexicalConstraint m g s, InputCharParsing (m g s), TextualMonoid s)
                            => m g s Char
   default lexicalToken :: (LexicalConstraint m g s, InputCharParsing (m g s), TextualMonoid s)
                        => m g s a -> m g s a
   default identifierToken :: (LexicalConstraint m g s, InputCharParsing (m g s), TextualMonoid s)
                           => m g s s -> m g s s
   default identifier :: (LexicalConstraint m g s, Monad (m g s), Alternative (m g s), ParserInput (m g s) ~ s,
                          InputCharParsing (m g s), TextualMonoid s)
                      => m g s s
   default keyword :: (LexicalConstraint m g s, InputCharParsing (m g s),
                       ParserInput (m g s) ~ s, Show s, TextualMonoid s)
                   => s -> m g s ()
   lexicalWhiteSpace = takeCharsWhile isSpace *> skipMany (lexicalComment *> takeCharsWhile isSpace)
   someLexicalSpace = takeCharsWhile1 isSpace *> skipMany (lexicalComment *> takeCharsWhile isSpace)
                      <|> lexicalComment *> skipMany (takeCharsWhile isSpace *> lexicalComment)
   lexicalComment = empty
   lexicalSemicolon = lexicalToken (Text.Parser.Char.char ';')
   lexicalToken p = p <* lexicalWhiteSpace
   isIdentifierStartChar c = isLetter c || c == '_'
   isIdentifierFollowChar c = isAlphaNum c || c == '_'
   identifier = identifierToken (liftA2 mappend (satisfyCharInput (isIdentifierStartChar @g))
                                                (takeCharsWhile (isIdentifierFollowChar @g))) <?> "an identifier"
   identifierToken = lexicalToken
   keyword s = lexicalToken (string s *> notSatisfyChar (isIdentifierFollowChar @g)) <?> ("keyword " <> show s)
