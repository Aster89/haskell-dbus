{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TypeFamilies #-}

-- Copyright (C) 2009-2012 John Millikin <jmillikin@gmail.com>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

-- | Support for defining custom transport mechanisms. Most users will not
-- need to care about the types defined in this module.
module DBus.Transport
	( TransportError(..)
	, Transport(..)
	, TransportOpen(..)
	, TransportListen(..)
	, SocketTransport
	, socketTransportOptionBacklog
	) where

import           Control.Exception
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Map as Map
import           Data.Typeable (Typeable)
import           Network.Socket hiding (recv)
import           Network.Socket.ByteString (sendAll, recv)
import qualified System.Info

import           DBus
import           DBus.Util (readPortNumber, randomUUID)

-- | Thrown from transport methods when an error occurs.
data TransportError = TransportError String
	deriving (Eq, Show, Typeable)

instance Exception TransportError

-- | A 'Transport' can exchange bytes with a remote peer.
class Transport t where
	-- | Additional options that this transport type may use when establishing
	-- a connection.
	data TransportOptions t :: *
	
	-- | Default values for this transport's options.
	transportDefaultOptions :: TransportOptions t
	
	-- | Send a 'ByteString' over the transport.
	--
	-- Throws a 'TransportError' if an error occurs.
	transportPut :: t -> ByteString -> IO ()
	
	-- | Receive a 'ByteString' of the given size from the transport. The
	-- transport should block until sufficient bytes are available, and
	-- only return fewer than the requested amount if there will not be
	-- any more data.
	--
	-- Throws a 'TransportError' if an error occurs.
	transportGet :: t -> Int -> IO ByteString
	
	-- | Close an open transport, and release any associated resources
	-- or handles.
	transportClose :: t -> IO ()

-- | A 'Transport' which can open a connection to a remote peer.
class Transport t => TransportOpen t where
	-- | Open a connection to the given address, using the given options.
	--
	-- Throws a 'TransportError' if the connection could not be
	-- established.
	transportOpen :: TransportOptions t -> Address -> IO t

-- | A 'Transport' which can listen for and accept connections from remote
-- peers.
class Transport t => TransportListen t where
	-- | Used for transports that listen on a port or address.
	data TransportListener t :: *
	
	-- | Begin listening for connections on the given address, using the
	-- given options.
	--
	-- Throws a 'TransportError' if it's not possible to listen at that
	-- address (for example, if the port is already in use).
	transportListen :: TransportOptions t -> Address -> IO (TransportListener t)
	
	-- | Accept a new connection.
	--
	-- Throws a 'TransportError' if some error happens before the
	-- transport is ready to exchange bytes.
	transportAccept :: TransportListener t -> IO t
	
	-- | Close an open listener.
	transportListenerClose :: TransportListener t -> IO ()
	
	-- | Get the address to use to connect to a listener.
	transportListenerAddress :: TransportListener t -> Address

-- | Supports connecting over UNIX or TCP sockets.
--
-- UNIX sockets are similar to pipes, but exist as special files in the
-- filesystem. On Linux, /abstract sockets/ have a path-like address, but do
-- not actually have entries in the filesystem.
--
-- TCP sockets may use either IPv4 or IPv6.
newtype SocketTransport = SocketTransport Socket

instance Transport SocketTransport where
	data TransportOptions SocketTransport = SocketTransportOptions
		{
		-- | The maximum size of the connection queue for a listening
		-- socket.
		  socketTransportOptionBacklog :: Int
		}
	transportDefaultOptions = SocketTransportOptions 30
	transportPut (SocketTransport s) bytes = catchIOException (sendAll s bytes)
	transportGet (SocketTransport s) n = catchIOException (recv s n)
	transportClose (SocketTransport s) = catchIOException (sClose s)

instance TransportOpen SocketTransport where
	transportOpen _ a = case Char8.unpack (addressMethod a) of
		"unix" -> openUnix (addressParameters a)
		"tcp" -> openTcp (addressParameters a)
		method -> throwIO (TransportError ("Unknown address method: " ++ show method))

instance TransportListen SocketTransport where
	data TransportListener SocketTransport = SocketTransportListener Address Socket
	transportListen opts a = do
		(a', sock) <- case Char8.unpack (addressMethod a) of
			"unix" -> listenUnix (addressParameters a) opts
			"tcp" -> listenTcp (addressParameters a) opts
			method -> throwIO (TransportError ("Unknown address method: " ++ show method))
		return (SocketTransportListener a' sock)
	transportAccept (SocketTransportListener _ s) = catchIOException $ do
		(s', _) <- accept s
		return (SocketTransport s')
	transportListenerClose (SocketTransportListener _ s) = catchIOException (sClose s)
	transportListenerAddress (SocketTransportListener a _) = a

openUnix :: Map.Map ByteString ByteString -> IO SocketTransport
openUnix params = go where
	param key = Map.lookup (Char8.pack key) params
	
	tooMany = "Only one of 'path' or 'abstract' may be specified for the\
	          \ 'unix' transport."
	tooFew = "One of 'path' or 'abstract' must be specified for the\
	         \ 'unix' transport."
	
	path = case (param "path", param "abstract") of
		(Just x, Nothing) -> Right (Char8.unpack x)
		(Nothing, Just x) -> Right ('\x00' : Char8.unpack x)
		(Nothing, Nothing) -> Left tooFew
		_ -> Left tooMany
	
	go = case path of
		Left err -> throwIO (TransportError err)
		Right p -> catchIOException $ do
			sock <- socket AF_UNIX Stream defaultProtocol
			connect sock (SockAddrUnix p)
			return (SocketTransport sock)

openTcp :: Map.Map ByteString ByteString -> IO SocketTransport
openTcp params = go where
	param key = Map.lookup (Char8.pack key) params
	
	hostname = maybe "localhost" Char8.unpack (param "host")
	unknownFamily x = "Unknown socket family for TCP transport: " ++ show x
	getFamily = case fmap Char8.unpack (param "family") of
		Just "ipv4" -> Right AF_INET
		Just "ipv6" -> Right AF_INET6
		Nothing     -> Right AF_UNSPEC
		Just x      -> Left (unknownFamily x)
	missingPort = "TCP transport requires the `port' parameter."
	badPort x = "Invalid socket port for TCP transport: " ++ show x
	getPort = case param "port" of
		Nothing -> Left missingPort
		Just x -> case readPortNumber (Char8.unpack x) of
			Just port -> Right port
			Nothing -> Left (badPort x)
	
	getAddresses family = getAddrInfo (Just (defaultHints
		{ addrFlags = [AI_ADDRCONFIG]
		, addrFamily = family
		, addrSocketType = Stream
		})) (Just hostname) Nothing
	
	openSocket [] = throwIO (TransportError "openTcp: no addresses")
	openSocket (addr:addrs) = do
		tried <- Control.Exception.try $ bracketOnError
			(socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
			sClose
			(\sock -> do
				connect sock (addrAddress addr)
				return sock)
		case tried of
			Left err -> case addrs of
				[] -> throwIO (TransportError (show (err :: IOException)))
				_ -> openSocket addrs
			Right sock -> return sock
	
	go = case getPort of
		Left err -> throwIO (TransportError err)
		Right port -> case getFamily of
			Left err -> throwIO (TransportError err)
			Right family -> catchIOException $ do
				addrs <- getAddresses family
				sock <- openSocket (map (setPort port) addrs)
				return (SocketTransport sock)

listenUnix :: Map.Map ByteString ByteString -> TransportOptions SocketTransport -> IO (Address, Socket)
listenUnix params opts = getPath >>= go where
	param key = Map.lookup (Char8.pack key) params
	
	tooMany = "Only one of 'abstract', 'path', or 'tmpdir' may be\
	          \ specified for the 'unix' transport."
	tooFew = "One of 'abstract', 'path', or 'tmpdir' must be specified\
	         \ for the 'unix' transport."
	
	getPath = case (param "abstract", param "path", param "tmpdir") of
		(Just x, Nothing, Nothing) -> let
			addr = address_ "unix" [("abstract", Char8.unpack x)]
			path = '\x00' : Char8.unpack x
			in return (Right (addr, path))
		(Nothing, Just x, Nothing) -> let
			addr = address_ "unix" [("path", Char8.unpack x)]
			path = Char8.unpack x
			in return (Right (addr, path))
		(Nothing, Nothing, Just x) -> do
			uuid <- randomUUID
			let fileName = Char8.unpack x ++ "/haskell-dbus-" ++ uuid
			
			-- Abstract paths are supported on Linux, but not on
			-- other UNIX-like systems.
			let (addrParams, path) = if System.Info.os == "linux"
				then ([("abstract", fileName)], ('\x00' : fileName))
				else ([("path", fileName)], fileName)
			
			let addr = address_ "unix" addrParams
			return (Right (addr, path))
		(Nothing, Nothing, Nothing) -> return (Left tooFew)
		_ -> return (Left tooMany)
	
	go path = case path of
		Left err -> throwIO (TransportError err)
		Right (addr, p) -> catchIOException $ do
			sock <- socket AF_UNIX Stream defaultProtocol
			bindSocket sock (SockAddrUnix p)
			Network.Socket.listen sock (socketTransportOptionBacklog opts)
			return (addr, sock)

listenTcp :: Map.Map ByteString ByteString -> TransportOptions SocketTransport -> IO (Address, Socket)
listenTcp params opts = go where
	param key = Map.lookup (Char8.pack key) params
	
	unknownFamily x = "Unknown socket family for TCP transport: " ++ show x
	getFamily = case fmap Char8.unpack (param "family") of
		Just "ipv4" -> Right AF_INET
		Just "ipv6" -> Right AF_INET6
		Nothing     -> Right AF_UNSPEC
		Just x      -> Left (unknownFamily x)
	
	badPort x = "Invalid socket port for TCP transport: " ++ show x
	getPort = case param "port" of
		Nothing -> Right 0
		Just x -> case readPortNumber (Char8.unpack x) of
			Just port -> Right port
			Nothing -> Left (badPort x)
	
	paramBind = case param "bind" of
		Just x | Char8.unpack x == "*" -> Nothing
		Just x -> Just (Char8.unpack x)
		Nothing -> case param "host" of
			Just x -> Just (Char8.unpack x)
			Nothing -> Just "localhost"
	
	getAddresses family = getAddrInfo (Just (defaultHints
		{ addrFlags = [AI_ADDRCONFIG, AI_PASSIVE]
		, addrFamily = family
		, addrSocketType = Stream
		})) paramBind Nothing
	
	bindAddrs _ [] = throwIO (TransportError "listenTcp: no addresses")
	bindAddrs sock (addr:addrs) = do
		tried <- Control.Exception.try (bindSocket sock (addrAddress addr))
		case tried of
			Left err -> case addrs of
				[] -> throwIO (TransportError (show (err :: IOException)))
				_ -> bindAddrs sock addrs
			Right _ -> return ()
	
	sockAddr (PortNum port) = address_ "tcp" p where
		p = [("port", show port)] ++ hostParam ++ familyParam
		hostParam = case param "host" of
			Just x -> [("host", Char8.unpack x)]
			Nothing -> []
		familyParam = case param "family" of
			Just x -> [("family", Char8.unpack x)]
			Nothing -> []
	
	go = case getPort of
		Left err -> throwIO (TransportError err)
		Right port -> case getFamily of
			Left err -> throwIO (TransportError err)
			Right family -> catchIOException $ do
				sockAddrs <- getAddresses family
				
				sock <- (bracketOnError
					(do
						sock <- socket family Stream defaultProtocol
						setSocketOption sock ReuseAddr 1
						return sock)
					sClose
					(\sock -> do
						bindAddrs sock (map (setPort port) sockAddrs)
						return sock))
				
				Network.Socket.listen sock (socketTransportOptionBacklog opts)
				sockPort <- socketPort sock
				return (sockAddr sockPort, sock)

catchIOException :: IO a -> IO a
catchIOException io = do
	tried <- try io
	case tried of
		Right a -> return a
		Left err -> throwIO (TransportError (show (err :: IOException)))

address_ :: String -> [(String, String)] -> Address
address_ method params = addr where
	Just addr = address (Char8.pack method) (Map.fromList (do
		(key, val) <- params
		return (Char8.pack key, Char8.pack val)))

setPort :: PortNumber -> AddrInfo -> AddrInfo
setPort port info = case addrAddress info of
	(SockAddrInet  _ x) -> info { addrAddress = SockAddrInet port x }
	(SockAddrInet6 _ x y z) -> info { addrAddress = SockAddrInet6 port x y z }
	_ -> info
