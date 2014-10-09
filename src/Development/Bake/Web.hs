{-# LANGUAGE ScopedTypeVariables, RecordWildCards, OverloadedStrings #-}

module Development.Bake.Web(
    Input(..), Output(..), send, server
    ) where

import Development.Bake.Type hiding (run)
import Network.Wai.Handler.Warp hiding (Port)
import Network.Wai
import Control.DeepSeq
import Control.Exception
import Network.HTTP.Types.Status
import Network.HTTP hiding (Request)
import qualified Data.Text as Text
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import System.Console.CmdArgs.Verbosity


data Input = Input
    {inputURL :: [String]
    ,inputArgs :: [(String, String)]
    ,inputBody :: String
    } deriving Show

data Output
    = OutputString String
    | OutputHTML String
    | OutputFile FilePath
    | OutputError String
    | OutputMissing
      deriving Show

instance NFData Output where
    rnf (OutputString x) = rnf x
    rnf (OutputHTML x) = rnf x
    rnf (OutputFile x) = rnf x
    rnf (OutputError x) = rnf x
    rnf OutputMissing = ()


send :: (Host,Port) -> Input -> IO String
send (host,port) Input{..} = do
    let url = "http://" ++ host ++ ":" ++ show port ++ concatMap ('/':) inputURL ++
              concat (zipWith (++) ("?":repeat "&") [a ++ "=" ++ b | (a,b) <- inputArgs])
    whenLoud $ print ("sending",inputBody,host,port)
    res <- simpleHTTP (getRequest url)
        {rqBody=inputBody
        ,rqHeaders=[Header HdrContentType "application/x-www-form-urlencoded", Header HdrContentLength $ show $ length inputBody]}
    case res of
        Left err -> error $ show err
        Right r | rspCode r /= (2,0,0) -> error $
                    "Incorrect code: " ++ show (rspCode r,rspReason r,url) ++ "\n" ++ rspBody r
                | otherwise -> return $ rspBody r


server :: Port -> (Input -> IO Output) -> IO ()
server port act = runSettings (setOnException exception $ setPort port defaultSettings) $ \req reply -> do
    bod <- strictRequestBody req
    whenLoud $ print ("receiving",bod,requestHeaders req,port)
    let pay = Input
            (map Text.unpack $ pathInfo req)
            [(BS.unpack a, maybe "" BS.unpack b) | (a,b) <- queryString req]
            (LBS.unpack bod)
    res <- act pay
    reply $ case res of
        OutputFile file -> responseFile status200 [] file Nothing
        OutputString msg -> responseLBS status200 [] $ LBS.pack msg
        OutputHTML msg -> responseLBS status200 [("content-type","text/html")] $ LBS.pack msg
        OutputError msg -> responseLBS status500 [] $ LBS.pack msg
        OutputMissing -> responseLBS status404 [] $ LBS.pack "Resource not found"

exception :: Maybe Request -> SomeException -> IO ()
exception r e
    | Just (_ :: InvalidRequest) <- fromException e = return ()
    | otherwise = putStrLn $ "Error when processing " ++ maybe "Nothing" (show . rawPathInfo) r ++
                             "\n    " ++ show e
