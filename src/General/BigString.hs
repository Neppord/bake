
module General.BigString(
    BigString,
    bigStringFromFile, bigStringFromText, bigStringFromString, bigStringFromByteString,
    bigStringToFile, bigStringToText, bigStringToString, bigStringWithString, bigStringToByteString,
    bigStringBackEnd, withBigStringPart
    ) where

import System.IO.Extra
import Control.DeepSeq
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.Concurrent
import System.IO.Unsafe
import Control.Applicative
import Control.Exception
import Data.Monoid
import System.Directory
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Network.Wai.Parse
import Data.Function
import Control.Monad
import Network.HTTP.Client.MultipartFormData
import Prelude

limit = 5000 -- above this level, save to disk


---------------------------------------------------------------------
-- DEFINITION

data BigString = Memory T.Text
               | File FilePath (ForeignPtr ())

instance Monoid BigString where
    mempty = bigStringFromText mempty
    mappend (Memory a) (Memory b) | T.length a + T.length b <= limit = Memory $ a <> b
    mappend x y = unsafeFromFile $ \out -> withFile out WriteMode $ \out -> do
        hSetBinaryMode out True
        forM_ [x,y] $ \inp -> bigStringWithFile inp $ \inp -> withFile inp ReadMode $ \inp -> do
            hSetBinaryMode inp True
            src <- LBS.hGetContents inp
            LBS.hPut out src

instance NFData BigString where
    rnf (Memory x) = rnf x
    rnf (File a b) = rnf a `seq` b `seq` ()

instance Show BigString where
    show _ = "<BigString>"

---------------------------------------------------------------------
-- PRIMITIVES

bigStringFromFile :: (FilePath -> IO a) -> IO (BigString, a)
bigStringFromFile op = do
    (file, close) <- newTempFile
    ptr <- newForeignPtr_ nullPtr
    Foreign.Concurrent.addForeignPtrFinalizer ptr close
    res <- withForeignPtr ptr $ const $ op file
    return (File file ptr, res)

-- Not exported, as it is a bit unsafe - two invariants:
-- 1) must not use file after returning
-- 2) must not write to the file
bigStringWithFile :: BigString -> (FilePath -> IO a) -> IO a
bigStringWithFile (Memory x) op = withTempFile $ \file -> do T.writeFile file x; op file
bigStringWithFile (File file ptr) op = withForeignPtr ptr $ const $ op file


{-# NOINLINE unsafeFromFile #-}
unsafeFromFile :: (FilePath -> IO ()) -> BigString
unsafeFromFile op = unsafePerformIO $ fst <$> bigStringFromFile op

{-# NOINLINE unsafeWithFile #-}
unsafeWithFile :: BigString -> (FilePath -> IO a) -> a
unsafeWithFile x op = unsafePerformIO $ bigStringWithFile x op


---------------------------------------------------------------------
-- DERIVED

bigStringFromText :: T.Text -> BigString
bigStringFromText x | T.length x <= limit = Memory x
                    | otherwise = unsafeFromFile $ \file -> withFile file WriteMode $ \h -> do hSetEncoding h utf8; T.hPutStr h x

bigStringFromString :: String -> BigString
bigStringFromString x | null $ drop limit x = Memory $ T.pack x
                      | otherwise = unsafeFromFile (`writeFileUTF8` x)

bigStringToFile :: BigString -> FilePath -> IO ()
bigStringToFile (Memory x) out = T.writeFile out x
bigStringToFile x out = bigStringWithFile x $ \file -> copyFile file out

bigStringToText :: BigString -> T.Text
bigStringToText (Memory x) = x
bigStringToText x = unsafeWithFile x $ \file -> withFile file ReadMode $ \h -> do hSetEncoding h utf8; T.hGetContents h

bigStringToString :: BigString -> String
bigStringToString (Memory x) = T.unpack x
bigStringToString x = unsafeWithFile x readFileUTF8'

bigStringWithString :: NFData a => BigString -> (String -> a) -> a
bigStringWithString (Memory x) op = let res = op $ T.unpack x in rnf res `seq` res
bigStringWithString x op = unsafeWithFile x $ \file -> do
    src <- readFile file
    let res = op src
    evaluate $ rnf res
    return res

bigStringFromByteString :: BS.ByteString -> BigString
bigStringFromByteString x | BS.length x <= limit = Memory $ T.decodeUtf8 x
                          | otherwise = unsafeFromFile $ \file -> withFile file WriteMode $ \h -> do hSetBinaryMode h True; BS.hPutStr h x

bigStringToByteString :: BigString -> BS.ByteString
bigStringToByteString (Memory x) = T.encodeUtf8 x
bigStringToByteString x = unsafeWithFile x $ \file -> withFile file ReadMode $ \h -> do hSetBinaryMode h True; BS.hGetContents h


---------------------------------------------------------------------
-- WEBBY

bigStringBackEnd :: BackEnd BigString
bigStringBackEnd _ _ ask = fmap fst $ bigStringFromFile $ \file -> do
    withFile file WriteMode $ \h -> do
        fix $ \loop -> do
            bs <- ask
            unless (BS.null bs) $ do
                BS.hPut h bs
                loop

withBigStringPart :: String -> BigString -> (Part -> IO a) -> IO a
withBigStringPart name (Memory x) op = op $ partBS (T.pack name) (T.encodeUtf8 x)
withBigStringPart name body op = bigStringWithFile body $ \file -> op $ partFileSourceChunked (T.pack name) file