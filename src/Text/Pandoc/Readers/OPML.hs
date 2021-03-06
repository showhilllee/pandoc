{-# LANGUAGE FlexibleContexts #-}
module Text.Pandoc.Readers.OPML ( readOPML ) where
import Control.Monad.State
import Data.Char (toUpper)
import Data.Default
import Data.Generics
import Text.HTML.TagSoup.Entity (lookupEntity)
import Text.Pandoc.Builder
import Text.Pandoc.Class (PandocMonad)
import Text.Pandoc.Options
import Text.Pandoc.Readers.HTML (readHtml)
import Text.Pandoc.Readers.Markdown (readMarkdown)
import Text.XML.Light

type OPML m = StateT OPMLState m

data OPMLState = OPMLState{
                        opmlSectionLevel :: Int
                      , opmlDocTitle     :: Inlines
                      , opmlDocAuthors   :: [Inlines]
                      , opmlDocDate      :: Inlines
                      } deriving Show

instance Default OPMLState where
  def = OPMLState{ opmlSectionLevel = 0
                 , opmlDocTitle = mempty
                 , opmlDocAuthors = []
                 , opmlDocDate = mempty
                  }

readOPML :: PandocMonad m => ReaderOptions -> String -> m Pandoc
readOPML _ inp  = do
  (bs, st') <- flip runStateT def (mapM parseBlock $ normalizeTree $ parseXML inp)
  return $
    setTitle (opmlDocTitle st') $
    setAuthors (opmlDocAuthors st') $
    setDate (opmlDocDate st') $
    doc $ mconcat bs

-- normalize input, consolidating adjacent Text and CRef elements
normalizeTree :: [Content] -> [Content]
normalizeTree = everywhere (mkT go)
  where go :: [Content] -> [Content]
        go (Text (CData CDataRaw _ _):xs) = xs
        go (Text (CData CDataText s1 z):Text (CData CDataText s2 _):xs) =
           Text (CData CDataText (s1 ++ s2) z):xs
        go (Text (CData CDataText s1 z):CRef r:xs) =
           Text (CData CDataText (s1 ++ convertEntity r) z):xs
        go (CRef r:Text (CData CDataText s1 z):xs) =
             Text (CData CDataText (convertEntity r ++ s1) z):xs
        go (CRef r1:CRef r2:xs) =
             Text (CData CDataText (convertEntity r1 ++ convertEntity r2) Nothing):xs
        go xs = xs

convertEntity :: String -> String
convertEntity e = maybe (map toUpper e) id (lookupEntity e)

-- convenience function to get an attribute value, defaulting to ""
attrValue :: String -> Element -> String
attrValue attr elt =
  case lookupAttrBy (\x -> qName x == attr) (elAttribs elt) of
    Just z  -> z
    Nothing -> ""

-- exceptT :: PandocMonad m => Either PandocError a -> OPML m a
-- exceptT = either throwError return

asHtml :: PandocMonad m => String -> OPML m Inlines
asHtml s =
  (\(Pandoc _ bs) -> case bs of
                                [Plain ils] -> fromList ils
                                _           -> mempty) <$> (lift $ readHtml def s)

asMarkdown :: PandocMonad m => String -> OPML m Blocks
asMarkdown s = (\(Pandoc _ bs) -> fromList bs) <$> (lift $ readMarkdown def s)

getBlocks :: PandocMonad m => Element -> OPML m Blocks
getBlocks e =  mconcat <$> (mapM parseBlock $ elContent e)

parseBlock :: PandocMonad m => Content -> OPML m Blocks
parseBlock (Elem e) =
  case qName (elName e) of
        "ownerName"    -> mempty <$ modify (\st ->
                              st{opmlDocAuthors = [text $ strContent e]})
        "dateModified" -> mempty <$ modify (\st ->
                              st{opmlDocDate = text $ strContent e})
        "title"        -> mempty <$ modify (\st ->
                              st{opmlDocTitle = text $ strContent e})
        "outline" -> gets opmlSectionLevel >>= sect . (+1)
        "?xml"  -> return mempty
        _       -> getBlocks e
   where sect n = do headerText <- asHtml $ attrValue "text" e
                     noteBlocks <- asMarkdown $ attrValue "_note" e
                     modify $ \st -> st{ opmlSectionLevel = n }
                     bs <- getBlocks e
                     modify $ \st -> st{ opmlSectionLevel = n - 1 }
                     let headerText' = case map toUpper (attrValue "type" e) of
                                             "LINK"  -> link
                                               (attrValue "url" e) "" headerText
                                             _ -> headerText
                     return $ header n headerText' <> noteBlocks <> bs
parseBlock _ = return mempty
