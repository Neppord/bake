{-# LANGUAGE RankNTypes, TupleSections, GADTs, RecordWildCards #-}

module Development.Bake.Server.Memory(
    ClientInfo(..), Memory(..),
    newMemory, stateFailure
    ) where

import Development.Bake.Server.Store
import qualified Data.Map as Map
import Development.Bake.Core.Type
import Data.Time
import Development.Bake.Core.Message
import Control.DeepSeq

stateFailure = State ""


---------------------------------------------------------------------
-- THE DATA TYPE

data ClientInfo = ClientInfo
    {ciPingTime :: UTCTime
    ,ciPing :: Ping
    ,ciAlive :: Bool
    ,ciTests :: Map.Map (Point, Maybe Test) Bool -- if a single failure, set to False
    } deriving (Eq,Show)

data Memory = Memory
    {simulated :: Bool
        -- ^ Are we running in a simulation (don't spawn separate process)
    ,authors :: [Author]
        -- ^ Author
    ,store :: Store
        -- ^ All the information on disk
    ,fatal :: [String]
        -- ^ A list of fatal error messages that have been raised by the server
    ,clients :: Map.Map Client ClientInfo
        -- ^ Latest time of a ping sent by each client
    ,running :: [(UTCTime, Question)]
        -- ^ Questions you have sent to clients and are waiting for.
    ,paused :: Bool
        -- ^ Pretend the queued is empty
    ,active :: Point
        -- ^ the target we are working at (some may already be rejected)
    }

newMemory :: Store -> (State, Answer) -> IO Memory
newMemory store (state, answer) = do
    store <- storeUpdate store [IUState state answer Nothing]
    return $ Memory False [] store [] Map.empty [] False (state, [])

instance NFData Memory where
    rnf Memory{..} = ()