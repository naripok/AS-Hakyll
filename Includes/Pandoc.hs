{-# LANGUAGE OverloadedStrings #-}

module Includes.Pandoc (pandocHtml5Compiler) where

import Control.Applicative ((<$>))
import Control.Concurrent (forkIO)
import Control.Exception
import Crypto.Hash
import Hakyll.Web.Pandoc
import Hakyll.Core.Compiler
import Hakyll.Core.Item
import Text.Blaze.Html (preEscapedToHtml, (!))
import Text.Blaze.Html.Renderer.String (renderHtml)
import Text.Pandoc
import Text.Pandoc.Definition
import Text.Pandoc.Options
import Text.Pandoc.Walk (walk)
import System.Directory
import System.Process
import System.IO (hClose, hGetContents, hPutStr, hSetEncoding, localeEncoding)
import System.IO.Error (isDoesNotExistError)
import System.IO.Unsafe
import qualified Data.ByteString.Char8 as C (ByteString, pack)
import qualified Data.Set as S
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

pandocHtml5Compiler :: FilePath -> Compiler (Item String)
pandocHtml5Compiler storePath = do
    pandocCompilerWithTransform readerOpts writerOpts (readTime . (walk $ pygments storePath))

readTime :: Pandoc -> Pandoc
readTime p@(Pandoc meta blocks) = (Pandoc meta (ert:blocks))
  where ert = Para [ Span ertSpan [ Str "Reading Time: ", Str $ timeEstimateString p ++ "." ] ]

ertSpan :: Attr
ertSpan = ("ert", [], [])

timeEstimateString :: Pandoc -> String
timeEstimateString = toClockString . timeEstimateSeconds

toClockString :: Int -> String
toClockString i
    | i >= 60 * 60 = show hours   ++ "h " ++ show minutes ++ "m " ++ show seconds ++ "s"
    | i >= 60      = show minutes ++ "m " ++ show seconds ++ "s"
    | otherwise    = show seconds ++ "s"
  where
    hours   = i `quot` (60 * 60)
    minutes = (i `rem` (60 * 60)) `quot` 60
    seconds = i `rem` 60

timeEstimateSeconds :: Pandoc -> Int
timeEstimateSeconds = (`quot` 5) . nrWords

nrWords :: Pandoc -> Int
nrWords = (`quot` 5) . nrLetters

nrLetters :: Pandoc -> Int
nrLetters (Pandoc _ bs) = sum $ map cb bs
  where
    cbs = sum . map cb
    cbss = sum . map cbs
    cbsss = sum . map cbss

    cb :: Block -> Int
    cb (Plain is) = cis is
    cb (Para is) = cis is
    cb (CodeBlock _ s) = length s
    cb (RawBlock _ s) = length s
    cb (BlockQuote bs) = cbs bs
    cb (OrderedList _ bss) = cbss bss
    cb (BulletList bss) = cbss bss
    cb (DefinitionList ls) = sum $ map (\(is, bss) -> cis is + cbss bss) ls
    cb (Header _ _ is) = cis is
    cb HorizontalRule = 0
    cb (Table is _ _ tc tcs) = cis is + cbss tc + cbsss tcs
    cb (Div _ bs) = cbs bs
    cb Null = 0

    cis = sum . map ci
    ciss = sum . map cis

    ci :: Inline -> Int
    ci (Str s) = length s
    ci (Emph is) = cis is
    ci (Strong is) = cis is
    ci (Strikeout is) = cis is
    ci (Superscript is) = cis is
    ci (Subscript is) = cis is
    ci (SmallCaps is) = cis is
    ci (Quoted _ is) = cis is
    ci (Cite _ is) = cis is
    ci (Code _ s) = length s
    ci Space = 1
    ci SoftBreak = 1
    ci LineBreak = 1
    ci (Math _ s) = length s
    ci (RawInline _ s) = length s
    ci (Link _ is (_, s)) = cis is + length s
    ci (Image _ is (_, s)) = cis is + length s
    ci (Note bs) = cbs bs

cache :: String -> String -> FilePath -> String
cache code lang storePath = unsafePerformIO $ do
  let pathStem = storePath ++ "/pygments"

  _ <- createDirectoryIfMissing True pathStem

  let path = pathStem ++ "/" ++ newhash
      newhash = sha1 code

  readFile path `catch` handleExists path
  where cacheit path = do
          colored <- pygmentize lang code
          writeFile path colored
          return colored
        sha1 :: String -> String
        sha1 = show . sha1hash . C.pack
          where sha1hash = hash :: C.ByteString -> Digest SHA1
        handleExists :: FilePath -> IOError -> IO String
        handleExists path e
          | isDoesNotExistError e = cacheit path
          | otherwise = throwIO e

pygments :: FilePath -> Block -> Block
pygments storePath (CodeBlock (_, classes, keyvals) contents) =
  let lang = case lookup "lang" keyvals of
               Just language -> language
               Nothing -> if not . null $ classes
                            then head classes
                            else "text"
      text = lookup "text" keyvals
      colored = renderHtml $ H.div ! A.class_ (H.toValue $ "code-container " ++ lang) $ do
                  preEscapedToHtml $ cache contents lang storePath
      caption = maybe "" (renderHtml . H.figcaption . H.span . preEscapedToHtml) text
      composed = renderHtml $ H.figure ! A.class_ "code" $ do
                   preEscapedToHtml $ colored ++ caption
  in RawBlock "html" composed
pygments _ x = x

pygmentize :: String -> String -> IO String
pygmentize lang contents = do
  let process = (shell ("pygmentize -f html -l " ++ lang ++ " -P encoding=utf-8")) {
                  std_in = CreatePipe, std_out = CreatePipe, close_fds = True}
      writer h input = do
        hSetEncoding h localeEncoding
        hPutStr h input
      reader h = do
        hSetEncoding h localeEncoding
        hGetContents h

  (Just stdin, Just stdout, _, _) <- createProcess process

  _ <- forkIO $ do
    writer stdin contents
    hClose stdin

  reader stdout

readerOpts :: ReaderOptions
readerOpts =
  let extensions =
        S.fromList [ Ext_tex_math_dollars
                   , Ext_inline_code_attributes
                   , Ext_abbreviations
                   ]
  in def { readerSmart = True
         , readerExtensions = S.union extensions (writerExtensions def)
         }

writerOpts :: WriterOptions
writerOpts = def { writerHTMLMathMethod = MathJax ""
                 , writerHighlight = False
                 , writerHtml5 = True
                 }
