module Main exposing (main)

import Url as Url
import Url.Builder as Url
import Random as Random
import Task as Task
import Time as Time
import Debug exposing (toString, log)
import Dict exposing (Dict)
import Dict as Dict
import Set as Set
import Set exposing (Set)
import Browser
import Html exposing (Html, button, div, text, datalist, option, input, form, br, a)
import Html.Events exposing (onClick, onInput, onSubmit)
import Html.Attributes as A
import Parser exposing (..)
import Parser as Parser
import Result.Extra exposing (combineMap)

type Msg = Input String
         | Guess
         | SetTime (Time.Zone, Time.Posix)

type TypeElem
  = Literal String
  | Ident String

type alias Signature = List TypeElem

type alias Function =
  { name : String
  , signature : Signature
  }

type alias Model =
  { answer : Maybe Function
  , guesses : List Function
  , knownIdents : Set String
  , input : String
  }

main =
         Browser.element
           { init = init
           , update = update
           , view = view
           , subscriptions = \_ -> Sub.none
           }

init : () -> (Model, Cmd Msg)
init _ =
  ( { answer = Nothing
    , guesses = []
    , knownIdents = Set.empty
    , input = ""
    }
  , Time.now
      |> Task.andThen (\now -> Task.map (\here -> (here, now)) Time.here)
      |> Task.perform SetTime
  )

getAnswer : Time.Zone -> Time.Posix -> Dict String Signature -> Maybe Function
getAnswer here now allFuncs =
  let
      day = Time.toDay here now
      month = case Time.toMonth here now of
                     Time.Jan -> 1
                     Time.Feb -> 2
                     Time.Mar -> 3
                     Time.Apr -> 4
                     Time.May -> 5
                     Time.Jun -> 6
                     Time.Jul -> 7
                     Time.Aug -> 8
                     Time.Sep -> 9
                     Time.Oct -> 10
                     Time.Nov -> 11
                     Time.Dec -> 12
      year = Time.toYear here now
      seed = Random.initialSeed (day + month + year + 2)
      maxIndex = Dict.size allFuncs - 1
      (randomIndex, _) = Random.step (Random.int 0 maxIndex) seed
      randomKey = Dict.keys allFuncs
                     |> List.drop randomIndex
                     |> List.head
      randomValue = randomKey
                     |> Maybe.andThen (\k -> (Dict.get k allFuncs)
                                               |> Maybe.map (\s -> { name = k, signature = s }))
   in
      log (toString randomKey) randomValue

getIdents : Signature -> Set String
getIdents elems =
  let
      keepIdent e =
        case e of
          Ident i -> Just i
          _       -> Nothing
   in elems
        |> List.filterMap keepIdent
        |> Set.fromList

garbleName : String -> String
garbleName original = String.repeat (String.length original) "❓"

garble : Set String -> Signature -> String
garble knownIdents sig =
  let
      garbleElem e =
        case e of
          Literal s -> s
          Ident x ->
            if Set.member x knownIdents
            then x
            else "🤷"
  in
     sig
       |> List.map garbleElem
       |> String.concat

display : Signature -> String
display sig =
  let
      displayElem e =
        case e of
          Literal s -> s
          Ident x -> x
   in
      sig
        |> List.map displayElem
        |> String.concat

update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
  let
      new =
        case (results, model.answer) of
          (Err x, _) -> model
          (Ok allFuncs, answer) ->
            case msg of
              SetTime (here, now) ->
                let
                    a = getAnswer here now allFuncs
                 in
                    { model | answer = a }
              Input i ->
                { model | input = i }
              Guess ->
                if List.member model.input (List.map .name model.guesses)
                then model
                else
                  case Dict.get model.input allFuncs of
                    Nothing -> { model | input = "" }
                    Just signature ->
                      let
                          newIdents = getIdents signature
                          g = { name = model.input, signature = signature }
                       in
                          { model |
                              guesses = model.guesses ++ [g],
                              knownIdents = Set.union model.knownIdents newIdents,
                              input = ""
                              }
   in
      (new, Cmd.none)

viewGuess answer guess =
  div [] [ text guess.name
         , text " :: "
         , text (display guess.signature)
         , text (if guess.name == answer.name
                 then "🎉"
                 else "❌")
         ]

view : Model -> Html Msg
view model =
  let
      garbled a = garble model.knownIdents
                         a.signature
      possibilities allFuncs =
                      allFuncs
                        |> Dict.keys
                        |> List.map (\name -> option [A.value name] [])
                        |> datalist [A.id "function-names"]
      nameInput = form [onSubmit Guess]
        [ input [onInput Input, A.list "function-names", A.value model.input] []
        , br [] []
        , button [A.type_ "submit"] [text "guess"]
        ]
  in
     case (results, model.answer) of
       (Err x, _) -> div [] [text (toString x)]
       (_, Nothing) -> div [] [text "loading"]
       (Ok allFuncs, Just answer) ->
         if List.head (List.reverse model.guesses) == model.answer
         then
            gameIsWon model answer
         else
            div []
              [ div [] [ text (garbleName answer.name)
                       , text " :: "
                       , text (garbled answer)
                       ]
              , viewGuesses answer model.guesses
              , possibilities allFuncs
              , nameInput
              ]

viewGuesses : Function -> List Function -> Html Msg
viewGuesses answer guesses =
  guesses
    |> List.map (viewGuess answer)
    |> div []

gameIsWon : Model -> Function -> Html Msg
gameIsWon model answer =
  div []
    [ viewGuesses answer model.guesses
    , a [A.href (twitterUrl model)] [text "Share on twitter"]
    ]

twitterUrl : Model -> String
twitterUrl model =
  Url.crossOrigin
    "https://twitter.com"
    ["intent", "tweet"]
    [Url.string "text" (twitterMessage model)]

twitterMessage : Model -> String
twitterMessage model = String.join " "
  [ "I've found today's https://haskle.net function in"
  , String.fromInt (List.length model.guesses)
  , "trie(s)!"
  ]

func : Parser Function
func = succeed Function
         |= variable { start = \_ -> True
                     , inner = \c -> c /= ' '
                     , reserved = Set.empty
                     }
         |. spaces
         |. symbol "::"
         |. spaces
         |= sigParser
         |. end

sigParser : Parser Signature
sigParser =
  let
      go revItems = oneOf
           [ succeed (\item -> Loop (item :: revItems))
               |= typeElem
           , succeed ()
               |> map (\_ -> Done (List.reverse revItems))
           ]
   in
      loop [] go

typeElem : Parser TypeElem
typeElem = oneOf
  [ Parser.map Literal sigLiteral
  , Parser.map Ident sigIdent
  ]

sigLiteral : Parser String
sigLiteral = getChompedString <|
  succeed ()
    |. chompIf (\c -> not (Char.isAlphaNum c))
    |. chompWhile (\c -> not (Char.isAlphaNum c))

sigIdent : Parser String
sigIdent = getChompedString <|
  succeed ()
    |. chompIf (\c -> Char.isAlphaNum c)
    |. chompWhile (\c -> Char.isAlphaNum c)

results : Result (List DeadEnd) (Dict String Signature)
results =
  case combineMap (run func) rawFuncs of
    Ok parsedFuncs ->
         parsedFuncs
           |> List.map (\f -> (f.name, f.signature))
           |> Dict.fromList
           |> Ok
    Err x -> Err x

rawFuncs : List String
rawFuncs =
  [ "(!!) :: [a] -> Int -> a"
  , "($) :: (a -> b) -> a -> b"
  , "($!) :: (a -> b) -> a -> b"
  , "(&&) :: Bool -> Bool -> Bool"
  , "(++) :: [a] -> [a] -> [a]"
  , "(.) :: (b -> c) -> (a -> b) -> a -> c"
  , "(<$>) :: Functor f => (a -> b) -> f a -> f b"
  , "(=<<) :: Monad m => (a -> m b) -> m a -> m b"
  , "pure :: Applicative f => a -> f a"
  , "(<*>) :: Applicative f => f (a -> b) -> f a -> f b"
  , "liftA2 :: Applicative f => (a -> b -> c) -> f a -> f b -> f c"
  , "(*>) :: Applicative f => f a -> f b -> f b"
  , "(<*) :: Applicative f => f a -> f b -> f a"
  , "minBound :: Bounded a => a"
  , "maxBound :: Bounded a => a"
  , "succ :: Enum a => a -> a"
  , "pred :: Enum a => a -> a"
  , "toEnum :: Enum a => Int -> a"
  , "fromEnum :: Enum a => a -> Int"
  , "enumFrom :: Enum a => a -> [a]"
  , "enumFromThen :: Enum a => a -> a -> [a]"
  , "enumFromTo :: Enum a => a -> a -> [a]"
  , "enumFromThenTo :: Enum a => a -> a -> a -> [a]"
  , "(==) :: Eq a => a -> a -> Bool"
  , "(/=) :: Eq a => a -> a -> Bool"
  , "pi :: Floating a => a"
  , "exp :: Floating a => a -> a"
  , "log :: Floating a => a -> a"
  , "sqrt :: Floating a => a -> a"
  , "(**) :: Floating a => a -> a -> a"
  , "logBase :: Floating a => a -> a -> a"
  , "sin :: Floating a => a -> a"
  , "cos :: Floating a => a -> a"
  , "tan :: Floating a => a -> a"
  , "asin :: Floating a => a -> a"
  , "acos :: Floating a => a -> a"
  , "atan :: Floating a => a -> a"
  , "sinh :: Floating a => a -> a"
  , "cosh :: Floating a => a -> a"
  , "tanh :: Floating a => a -> a"
  , "asinh :: Floating a => a -> a"
  , "acosh :: Floating a => a -> a"
  , "atanh :: Floating a => a -> a"
  , "log1p :: Floating a => a -> a"
  , "expm1 :: Floating a => a -> a"
  , "log1pexp :: Floating a => a -> a"
  , "log1mexp :: Floating a => a -> a"
  , "fold :: Foldable t => Monoid m => t m -> m"
  , "foldMap :: Foldable t => Monoid m => (a -> m) -> t a -> m"
  , "foldMap' :: Foldable t => Monoid m => (a -> m) -> t a -> m"
  , "foldr :: Foldable t => (a -> b -> b) -> b -> t a -> b"
  , "foldr' :: Foldable t => (a -> b -> b) -> b -> t a -> b"
  , "foldl :: Foldable t => (b -> a -> b) -> b -> t a -> b"
  , "foldl' :: Foldable t => (b -> a -> b) -> b -> t a -> b"
  , "foldr1 :: Foldable t => (a -> a -> a) -> t a -> a"
  , "foldl1 :: Foldable t => (a -> a -> a) -> t a -> a"
  , "toList :: Foldable t => t a -> [a]"
  , "null :: Foldable t => t a -> Bool"
  , "length :: Foldable t => t a -> Int"
  , "elem :: Foldable t => Eq a => a -> t a -> Bool"
  , "maximum :: Foldable t => Ord a => t a -> a"
  , "minimum :: Foldable t => Ord a => t a -> a"
  , "sum :: Foldable t => Num a => t a -> a"
  , "product :: Foldable t => Num a => t a -> a"
  , "(/) :: Fractional a => a -> a -> a"
  , "recip :: Fractional a => a -> a"
  , "fromRational :: Fractional a => Rational -> a"
  , "fmap :: Functor f => (a -> b) -> f a -> f b"
  , "(<$) :: Functor f => a -> f b -> f a"
  , "quot :: Integral a => a -> a -> a"
  , "rem :: Integral a => a -> a -> a"
  , "div :: Integral a => a -> a -> a"
  , "mod :: Integral a => a -> a -> a"
  , "quotRem :: Integral a => a -> a -> (a, a)"
  , "divMod :: Integral a => a -> a -> (a, a)"
  , "toInteger :: Integral a => a -> Integer"
  , "(>>=) :: Monad m => m a -> (a -> m b) -> m b"
  , "(>>) :: Monad m => m a -> m b -> m b"
  , "return :: Monad m => a -> m a"
  , "fail :: MonadFail => String -> m a"
  , "mempty :: Monoid a => a"
  , "mappend :: Monoid a => a -> a -> a"
  , "mconcat :: Monoid a => [a] -> a"
  , "(+) :: Num a => a -> a -> a"
  , "(-) :: Num a => a -> a -> a"
  , "(*) :: Num a => a -> a -> a"
  , "negate :: Num a => a -> a"
  , "abs :: Num a => a -> a"
  , "signum :: Num a => a -> a"
  , "fromInteger :: Num a => Integer -> a"
  , "compare :: Ord a => a -> a -> Ordering"
  , "(<) :: Ord a => a -> a -> Bool"
  , "(<=) :: Ord a => a -> a -> Bool"
  , "(>) :: Ord a => a -> a -> Bool"
  , "(>=) :: Ord a => a -> a -> Bool"
  , "max :: Ord a => a -> a -> a"
  , "min :: Ord a => a -> a -> a"
  , "readsPrec :: Read a => Int -> ReadS a"
  , "readList :: Read a => ReadS [a]"
  , "toRational :: Real a => a -> Rational"
  , "floatRadix :: RealFloat => a -> Integer"
  , "floatDigits :: RealFloat => a -> Int"
  , "floatRange :: RealFloat => a -> (Int, Int)"
  , "decodeFloat :: RealFloat => a -> (Integer, Int)"
  , "encodeFloat :: RealFloat => Integer -> Int -> a"
  , "exponent :: RealFloat => a -> Int"
  , "significand :: RealFloat => a -> a"
  , "scaleFloat :: RealFloat => Int -> a -> a"
  , "isNaN :: RealFloat => a -> Bool"
  , "isInfinite :: RealFloat => a -> Bool"
  , "isDenormalized :: RealFloat => a -> Bool"
  , "isNegativeZero :: RealFloat => a -> Bool"
  , "isIEEE :: RealFloat => a -> Bool"
  , "atan2 :: RealFloat => a -> a -> a"
  , "properFraction :: RealFrac => Integral b => a -> (b, a)"
  , "truncate :: RealFrac => Integral b => a -> b"
  , "round :: RealFrac => Integral b => a -> b"
  , "ceiling :: RealFrac => Integral b => a -> b"
  , "floor :: RealFrac => Integral b => a -> b"
  , "(<>) :: Semigroup a => a -> a -> a"
  , "sconcat :: Semigroup a => NonEmpty a -> a"
  , "stimes :: Semigroup a => Integral b => b -> a -> a"
  , "showsPrec :: Show a => Int -> a -> ShowS"
  , "show :: Show a => a -> String"
  , "showList :: Show a => [a] -> ShowS"
  , "traverse :: Traversable t => Applicative f => (a -> f b) -> t a -> f (t b)"
  , "sequenceA :: Traversable t => Applicative f => t (f a) -> f (t a)"
  , "mapM :: Traversable t => Monad m => (a -> m b) -> t a -> m (t b)"
  , "sequence :: Traversable t => Monad m => t (m a) -> m (t a)"
  , "(^) :: (Num a, Integral b) => a -> b -> a"
  , "(^^) :: (Fractional a, Integral b) => a -> b -> a"
  , "all :: Foldable t => (a -> Bool) -> t a -> Bool"
  , "and :: Foldable t => t Bool -> Bool"
  , "any :: Foldable t => (a -> Bool) -> t a -> Bool"
  , "appendFile :: FilePath -> String -> IO ()"
  , "asTypeOf :: a -> a -> a"
  , "break :: (a -> Bool) -> [a] -> ([a], [a])"
  , "concat :: Foldable t => t [a] -> [a]"
  , "concatMap :: Foldable t => (a -> [b]) -> t a -> [b]"
  , "const :: a -> b -> a"
  , "curry :: ((a, b) -> c) -> a -> b -> c"
  , "cycle :: [a] -> [a]"
  , "drop :: Int -> [a] -> [a]"
  , "dropWhile :: (a -> Bool) -> [a] -> [a]"
  , "either :: (a -> c) -> (b -> c) -> Either a b -> c"
  , "error :: HasCallStack => [Char] -> a"
  , "errorWithoutStackTrace :: [Char] -> a"
  , "even :: Integral a => a -> Bool"
  , "filter :: (a -> Bool) -> [a] -> [a]"
  , "flip :: (a -> b -> c) -> b -> a -> c"
  , "fromIntegral :: (Integral a, Num b) => a -> b"
  , "fst :: (a, b) -> a"
  , "gcd :: Integral a => a -> a -> a"
  , "getChar :: IO Char"
  , "getContents :: IO String"
  , "getLine :: IO String"
  , "head :: [a] -> a"
  , "id :: a -> a"
  , "init :: [a] -> [a]"
  , "interact :: (String -> String) -> IO ()"
  , "ioError :: IOError -> IO a"
  , "iterate :: (a -> a) -> a -> [a]"
  , "last :: [a] -> a"
  , "lcm :: Integral a => a -> a -> a"
  , "lex :: ReadS String"
  , "lines :: String -> [String]"
  , "lookup :: Eq a => a -> [(a, b)] -> Maybe b"
  , "map :: (a -> b) -> [a] -> [b]"
  , "mapM_ :: (Foldable t, Monad m) => (a -> m b) -> t a -> m ()"
  , "maybe :: b -> (a -> b) -> Maybe a -> b"
  , "not :: Bool -> Bool"
  , "notElem :: (Foldable t, Eq a) => a -> t a -> Bool"
  , "odd :: Integral a => a -> Bool"
  , "or :: Foldable t => t Bool -> Bool"
  , "otherwise :: Bool"
  , "print :: Show a => a -> IO ()"
  , "putChar :: Char -> IO ()"
  , "putStr :: String -> IO ()"
  , "putStrLn :: String -> IO ()"
  , "read :: Read a => String -> a"
  , "readFile :: FilePath -> IO String"
  , "readIO :: Read a => String -> IO a"
  , "readLn :: Read a => IO a"
  , "readParen :: Bool -> ReadS a -> ReadS a"
  , "reads :: Read a => ReadS a"
  , "realToFrac :: (Real a, Fractional b) => a -> b"
  , "repeat :: a -> [a]"
  , "replicate :: Int -> a -> [a]"
  , "reverse :: [a] -> [a]"
  , "scanl :: (b -> a -> b) -> b -> [a] -> [b]"
  , "scanl1 :: (a -> a -> a) -> [a] -> [a]"
  , "scanr :: (a -> b -> b) -> b -> [a] -> [b]"
  , "scanr1 :: (a -> a -> a) -> [a] -> [a]"
  , "seq :: a -> b -> b"
  , "sequence_ :: (Foldable t, Monad m) => t (m a) -> m ()"
  , "showChar :: Char -> ShowS"
  , "showParen :: Bool -> ShowS -> ShowS"
  , "showString :: String -> ShowS"
  , "shows :: Show a => a -> ShowS"
  , "snd :: (a, b) -> b"
  , "span :: (a -> Bool) -> [a] -> ([a], [a])"
  , "splitAt :: Int -> [a] -> ([a], [a])"
  , "subtract :: Num a => a -> a -> a"
  , "tail :: [a] -> [a]"
  , "take :: Int -> [a] -> [a]"
  , "takeWhile :: (a -> Bool) -> [a] -> [a]"
  , "uncurry :: (a -> b -> c) -> (a, b) -> c"
  , "undefined :: HasCallStack => a"
  , "unlines :: [String] -> String"
  , "until :: (a -> Bool) -> (a -> a) -> a -> a"
  , "unwords :: [String] -> String"
  , "unzip :: [(a, b)] -> ([a], [b])"
  , "unzip3 :: [(a, b, c)] -> ([a], [b], [c])"
  , "userError :: String -> IOError"
  , "words :: String -> [String]"
  , "writeFile :: FilePath -> String -> IO ()"
  , "zip :: [a] -> [b] -> [(a, b)]"
  , "zip3 :: [a] -> [b] -> [c] -> [(a, b, c)]"
  , "zipWith :: (a -> b -> c) -> [a] -> [b] -> [c]"
  , "zipWith3 :: (a -> b -> c -> d) -> [a] -> [b] -> [c] -> [d]"
  , "(||) :: Bool -> Bool -> Bool"
  ]
