//
//  GCDAsyncSocket.m
//  
//  This class is in the public domain.
//  Originally created by Robbie Hanson in Q4 2010.
//  Updated and maintained by Deusty LLC and the Mac development community.
//
//  http://code.google.com/p/cocoaasyncsocket/
//

#import "GCDAsyncSocket.h"

#if TARGET_OS_IPHONE
  #import <CFNetwork/CFNetwork.h>
#endif

#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <netinet/in.h>
#import <net/if.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <sys/ioctl.h>
#import <sys/poll.h>
#import <sys/uio.h>
#import <unistd.h>


#if 0

// Logging Enabled - See log level below

// Logging uses the CocoaLumberjack framework (which is also GCD based).
// http://code.google.com/p/cocoalumberjack/
// 
// It allows us to do a lot of logging without significantly slowing down the code.
#import "DDLog.h"

#define LogAsync   YES
#define LogContext 65535

#define LogObjc(flg, frmt, ...) LOG_OBJC_MAYBE(LogAsync, logLevel, flg, LogContext, frmt, ##__VA_ARGS__)
#define LogC(flg, frmt, ...)    LOG_C_MAYBE(LogAsync, logLevel, flg, LogContext, frmt, ##__VA_ARGS__)

#define LogError(frmt, ...)     LogObjc(LOG_FLAG_ERROR,   (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogWarn(frmt, ...)      LogObjc(LOG_FLAG_WARN,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogInfo(frmt, ...)      LogObjc(LOG_FLAG_INFO,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogVerbose(frmt, ...)   LogObjc(LOG_FLAG_VERBOSE, (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)

#define LogCError(frmt, ...)    LogC(LOG_FLAG_ERROR,   (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCWarn(frmt, ...)     LogC(LOG_FLAG_WARN,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCInfo(frmt, ...)     LogC(LOG_FLAG_INFO,    (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)
#define LogCVerbose(frmt, ...)  LogC(LOG_FLAG_VERBOSE, (@"%@: " frmt), THIS_FILE, ##__VA_ARGS__)

#define LogTrace()              LogObjc(LOG_FLAG_VERBOSE, @"%@: %@", THIS_FILE, THIS_METHOD)
#define LogCTrace()             LogC(LOG_FLAG_VERBOSE, @"%@: %s", THIS_FILE, __FUNCTION__)

// Log levels : off, error, warn, info, verbose
// Create a constant read only local attribute as static.  This means the value extends throughout the lifetime of this program
static const int logLevel = LOG_LEVEL_VERBOSE;

#else

// Logging Disabled

#define LogError(frmt, ...)     {}
#define LogWarn(frmt, ...)      {}
#define LogInfo(frmt, ...)      {}
#define LogVerbose(frmt, ...)   {}

#define LogCError(frmt, ...)    {}
#define LogCWarn(frmt, ...)     {}
#define LogCInfo(frmt, ...)     {}
#define LogCVerbose(frmt, ...)  {}

#define LogTrace()              {}
#define LogCTrace(frmt, ...)    {}

#endif

/**
 * Seeing a return statements within an inner block
 * can sometimes be mistaken for a return point of the enclosing method.
 * This makes inline blocks a bit easier to read.
**/
#define return_from_block  return

/**
 * A socket file descriptor is really just an integer.
 * It represents the index of the socket within the kernel.
 * This makes invalid file descriptor comparisons easier to read.
**/
#define SOCKET_NULL -1


NSString *const GCDAsyncSocketException = @"GCDAsyncSocketException";
NSString *const GCDAsyncSocketErrorDomain = @"GCDAsyncSocketErrorDomain";

#if !TARGET_OS_IPHONE
NSString *const GCDAsyncSocketSSLCipherSuites = @"GCDAsyncSocketSSLCipherSuites";

NSString *const GCDAsyncSocketSSLDiffieHellmanParameters = @"GCDAsyncSocketSSLDiffieHellmanParameters";
#endif


// Enumerator for socket flags
enum GCDAsyncSocketFlags
{
	kSocketStarted                 = 1 <<  0,  // If set, socket has been started (accepting/connecting)
	kConnected                     = 1 <<  1,  // If set, the socket is connected
	kForbidReadsWrites             = 1 <<  2,  // If set, no new reads or writes are allowed
	kReadsPaused                   = 1 <<  3,  // If set, reads are paused due to possible timeout
	kWritesPaused                  = 1 <<  4,  // If set, writes are paused due to possible timeout
	kDisconnectAfterReads          = 1 <<  5,  // If set, disconnect after no more reads are queued
	kDisconnectAfterWrites         = 1 <<  6,  // If set, disconnect after no more writes are queued
	kSocketCanAcceptBytes          = 1 <<  7,  // If set, we know socket can accept bytes. If unset, it's unknown.
	kReadSourceSuspended           = 1 <<  8,  // If set, the read source is suspended
	kWriteSourceSuspended          = 1 <<  9,  // If set, the write source is suspended
	kQueuedTLS                     = 1 << 10,  // If set, we've queued an upgrade to TLS
	kStartingReadTLS               = 1 << 11,  // If set, we're waiting for TLS negotiation to complete
	kStartingWriteTLS              = 1 << 12,  // If set, we're waiting for TLS negotiation to complete
	kSocketSecure                  = 1 << 13,  // If set, socket is using secure communication via SSL/TLS
#if TARGET_OS_IPHONE
	kAddedHandshakeListener        = 1 << 14,  // If set, rw streams have been added to handshake listener thread
	kSecureSocketHasBytesAvailable = 1 << 15,  // If set, CFReadStream has notified us of bytes available
#endif
};


// Enumerator for socket configuration
enum GCDAsyncSocketConfig
{
	kIPv4Disabled              = 1 << 0,  // If set, IPv4 is disabled
	kIPv6Disabled              = 1 << 1,  // If set, IPv6 is disabled
	kPreferIPv6                = 1 << 2,  // If set, IPv6 is preferred over IPv4
	kAllowHalfDuplexConnection = 1 << 3,  // If set, the socket will stay open even if the read stream closes
};

#if TARGET_OS_IPHONE
  static NSThread *sslHandshakeThread;
#endif

@interface GCDAsyncSocket (Private)
/////////////////////////////////////////
// Accepting
/////////////////////////////////////////


/*
    returns boolean
*/
- (BOOL)doAccept:(int)socketFD;


/////////////////////////////////////////
// Connecting
/////////////////////////////////////////

/*
 
*/
- (void)startConnectTimeout:(NSTimeInterval)timeout;

/*
 
 */
- (void)endConnectTimeout;

/*
 
 */
- (void)doConnectTimeout;

/*
 
 */
- (void)lookup:(int)aConnectIndex host:(NSString *)host port:(UInt16)port;

/*
 
 */
- (void)lookup:(int)aConnectIndex didSucceedWithAddress4:(NSData *)address4 address6:(NSData *)address6;

/*
 
 */
- (void)lookup:(int)aConnectIndex didFail:(NSError *)error;

/*
 
 */
- (BOOL)connectWithAddress4:(NSData *)address4 address6:(NSData *)address6 error:(NSError **)errPtr;

/*
 
 */
- (void)didConnect:(int)aConnectIndex;

/*
    param int
    param NSError
 */
- (void)didNotConnect:(int)aConnectIndex error:(NSError *)error;




/////////////////////////////////////////
// Disconnect
/////////////////////////////////////////

/*
    param NSError
 */
- (void)closeWithError:(NSError *)error;

/*
 
 */
- (void)close;

/*
 
 */
- (void)maybeClose;


/////////////////////////////////////////
// Errors
/////////////////////////////////////////
/*
    param msg
    returns NSError
 */
- (NSError *)badConfigError:(NSString *)msg;

/*
    param msg
    returns NSError
 */
- (NSError *)badParamError:(NSString *)msg;

/*
    param int
    returns NSError
 */
- (NSError *)gaiError:(int)gai_error;

/*
    returns NSError
 */
- (NSError *)errnoError;

/*
    param NSString
    returns NSError
 */
- (NSError *)errnoErrorWithReason:(NSString *)reason;

/*
    returns NSError
 */
- (NSError *)connectTimeoutError;

/*
    param msg
    returns NSError
 */
- (NSError *)otherError:(NSString *)msg;

/////////////////////////////////////////
// Diagnostics
/////////////////////////////////////////
/*
    returns NSString
 */
- (NSString *)connectedHost4;

/*
    returns NSString
 */
- (NSString *)connectedHost6;

/*
    returns unsigned 16-bit integer
 */
- (UInt16)connectedPort4;

/*
    returns unsigned 16-bit integer
 */
- (UInt16)connectedPort6;

/*
    returns NSString
 */
- (NSString *)localHost4;

/*
    returns NSString
 */
- (NSString *)localHost6;

/*
    returns unsigned 16-bit integer
 */
- (UInt16)localPort4;

/*
    returns unsigned 16-bit integer
 */
- (UInt16)localPort6;

/*
    param int
    returns NSString
 */
- (NSString *)connectedHostFromSocket4:(int)socketFD;

/*
    param int
    returns NSString
 */
- (NSString *)connectedHostFromSocket6:(int)socketFD;

/*
    param int
    returns unsigned 16-bit integer
 */
- (UInt16)connectedPortFromSocket4:(int)socketFD;

/*
    param int
    returns unsigned 16-bit integer
 */
- (UInt16)connectedPortFromSocket6:(int)socketFD;

/*
    param int
    returns NSString
 */
- (NSString *)localHostFromSocket4:(int)socketFD;

/*
    param int
    returns NSString
 */
- (NSString *)localHostFromSocket6:(int)socketFD;

/*
    param int
    returns unsigned 16-bit integer
 */
- (UInt16)localPortFromSocket4:(int)socketFD;

/*
    param int
    returns unsigned 16-bit integer
 */
- (UInt16)localPortFromSocket6:(int)socketFD;


/////////////////////////////////////////
// Utilities
/////////////////////////////////////////

/*
    param NSData
    param NSData
    param NSString
    param unsigned 16-bit integer
 */
- (void)getInterfaceAddress4:(NSData **)addr4Ptr
                    address6:(NSData **)addr6Ptr
             fromDescription:(NSString *)interfaceDescription
                        port:(UInt16)port;

/*
    param int
 */
- (void)setupReadAndWriteSourcesForNewlyConnectedSocket:(int)socketFD;

/*
 
 */
- (void)suspendReadSource;

/*
 
 */
- (void)resumeReadSource;

/*
 
 */
- (void)suspendWriteSource;

/*
 
 */
- (void)resumeWriteSource;


/////////////////////////////////////////
// Reading
/////////////////////////////////////////

/*

 */
- (void)maybeDequeueRead;

/*
 
 */
- (void)doReadData;

/*
 
 */
- (void)doReadEOF;

/*
 
 */
- (void)completeCurrentRead;

/*
 
 */
- (void)endCurrentRead;

/*
    param NSTimeInterval
 */
- (void)setupReadTimerWithTimeout:(NSTimeInterval)timeout;

/*
 
 */
- (void)doReadTimeout;

/*
    param NSTimeInterval
 */
- (void)doReadTimeoutWithExtension:(NSTimeInterval)timeoutExtension;


/////////////////////////////////////////
// Writing
/////////////////////////////////////////


 /**
 * Conditionally starts a new write.
 * 
 * It is called when:
 * - a user requests a write
 * - after a write request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
 **/

- (void)maybeDequeueWrite;

/*
 
 */
- (void)doWriteData;

/*
 
 */
- (void)completeCurrentWrite;

/*
    Cancel the timer and release the current writer
 */
- (void)endCurrentWrite;

/*
    param NSTimeInterval
 */
- (void)setupWriteTimerWithTimeout:(NSTimeInterval)timeout;

/*
 
 */
- (void)doWriteTimeout;

/*
    param NSTimeInterval
 */
- (void)doWriteTimeoutWithExtension:(NSTimeInterval)timeoutExtension;


/////////////////////////////////////////
// Security
/////////////////////////////////////////

/*
 
*/
- (void)maybeStartTLS;


#if !TARGET_OS_IPHONE

/*
 
*/
- (void)continueSSLHandshake;
#endif


/////////////////////////////////////////
// Class Methods
/////////////////////////////////////////

/*
    Class method
    param struct sockaddr_in (IP version 4)
    returns NSString
 */
+ (NSString *)hostFromAddress4:(struct sockaddr_in *)pSockaddr4;

/*
    Class method
    param struct sockaddr_in6
    returns NSString
 */
+ (NSString *)hostFromAddress6:(struct sockaddr_in6 *)pSockaddr6;

/*
    Class method
    param struck sockaddr_in (IP version 4)
    returns unsigned 16-bit integer
 */
+ (UInt16)portFromAddress4:(struct sockaddr_in *)pSockaddr4;

/*
    Class method
    param struct sockaddr_in6 (IP version 6)
    returns UInt16
 */
+ (UInt16)portFromAddress6:(struct sockaddr_in6 *)pSockaddr6;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncReadPacket encompasses the instructions for any given read.
 * The content of a read packet allows the code to determine if we're:
 *  - reading to a certain length
 *  - reading to a certain separator
 *  - or simply reading the first chunk of available data
**/
@interface GCDAsyncReadPacket : NSObject
{
  @public
	NSMutableData *buffer; // read buffer
	NSUInteger startOffset; // start offset for read buffer
	NSUInteger bytesDone; // bytes dones reading
	NSUInteger maxLength; // maximum length
	NSTimeInterval timeout; // the timeout value for reading from a host
	NSUInteger readLength; // read length
	NSData *term;   // terminator
	BOOL bufferOwner;  // whether there is a buffer owner
	NSUInteger originalBufferLength; // original buffer length
	long tag;
}

/*
    param NSMutableData
    param NSUInteger
    param NSUInteger
    param NSTimeInterval
    param NSUInteger
    param NSData
    param long
    returns id
*/
- (id)initWithData:(NSMutableData *)d
       startOffset:(NSUInteger)s
         maxLength:(NSUInteger)m
           timeout:(NSTimeInterval)t
        readLength:(NSUInteger)l
        terminator:(NSData *)e
               tag:(long)i;

/*
    param NSUInteger
 */
- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead;

/*
    The optimal read length with a default value, and whether should prebuffer
    param NSUInteger
    param BOOL
    returns NSUInteger
 */
- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr;

/*
    param NSUInteger
    returns NSUInteger
 */
- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable;

/*
    param NSUInteger
    param BOOL
    returns NSUInteger
 */
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr;

/*
    param NSData
    param BOOL
    return NSUInteger
 */
- (NSUInteger)readLengthForTermWithPreBuffer:(NSData *)preBuffer found:(BOOL *)foundPtr;

/*
    param ssize_t
    returns NSInteger
 */
- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes;

@end



@implementation GCDAsyncReadPacket

/*
    Initialize the GCDAsyncReadPacket
    param NSMutableData
    param NSUInteger
    param NSUInteger
    param NSTimeInterval
    param NSUInteger
    param NSData
    param long
    returns id
 */
- (id)initWithData:(NSMutableData *)d
       startOffset:(NSUInteger)s  // Number of characerts from the start
         maxLength:(NSUInteger)m  // maximum length
           timeout:(NSTimeInterval)t  // timeout for the packet
        readLength:(NSUInteger)l 
        terminator:(NSData *)e 
               tag:(long)i
{
	if((self = [super init]))
	{
		bytesDone = 0;
		maxLength = m;
		timeout = t;
		readLength = l;
		term = [e copy];
		tag = i;
		
		if (d) // if there is mutable data passed-in to initialize the method
		{
			buffer = [d retain];
			startOffset = s;
			bufferOwner = NO;
			originalBufferLength = [d length];
		}
		else // if there is not mutable data
		{
			if (readLength > 0)
            {
				buffer = [[NSMutableData alloc] initWithLength:readLength];
			}else{ // If readLength is less than or equal to zero
				buffer = [[NSMutableData alloc] initWithLength:0];
			}
			startOffset = 0;
			bufferOwner = YES;
			originalBufferLength = 0;
		}
	}
	return self;
}

/**
 * Increases the length of the buffer (if needed) to ensure a read of the given size will fit.
    param NSUInteger
**/
- (void)ensureCapacityForAdditionalDataOfLength:(NSUInteger)bytesToRead
{
    
	NSUInteger buffSize = [buffer length];
    
    // Determines the amount of the buffer used by adding the buffer
    // offset plus the bytes done 
	NSUInteger buffUsed = startOffset + bytesDone;
	
    // Computes the space available on the buffer by subtracting
    // the amount of the buffer used from the total buffer size
	NSUInteger buffSpace = buffSize - buffUsed;
	
    // If the bytes yet to read is greater than the buffer size then
    // increase the size of the buffer by the difference
	if (bytesToRead > buffSpace)
	{
        
		NSUInteger buffInc = bytesToRead - buffSpace;
		
		[buffer increaseLengthBy:buffInc];
	}
}

/**
 * This method is used when we do NOT know how much data is available to be read from the socket.
 * This method returns the default value unless it exceeds the specified readLength or maxLength.
 * 
 * Furthermore, the shouldPreBuffer decision is based upon the packet type,
 * and whether the returned value would fit in the current buffer without requiring a resize of the buffer.
    param NSUInteger
    param BOOL
    returns NSUInteger
**/
- (NSUInteger)optimalReadLengthWithDefault:(NSUInteger)defaultValue shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
    // Local variable for holding the result
	NSUInteger result;
	
	if (readLength > 0)
	{
		// Read a specific length of data
		
		result = MIN(defaultValue, (readLength - bytesDone));
		
		// There is no need to prebuffer since we know exactly how much data we need to read.
		// Even if the buffer isn't currently big enough to fit this amount of data,
		// it would have to be resized eventually anyway.
		
        // Whether should prebuffer the data
		if (shouldPreBufferPtr){
			*shouldPreBufferPtr = NO;
        }
	}
	else // if readLength is equal to zero
	{
		// Either reading until we find a specified terminator,
		// or we're simply reading all available data.
		// 
		// In other words, one of:
		// 
		// - readDataToData packet
		// - readDataWithTimeout packet
		
		if (maxLength > 0)
        {
			result =  MIN(defaultValue, (maxLength - bytesDone));
		}else{ // if maximum length is not greater than zero
			result = defaultValue;
		}
        
		// Since we don't know the size of the read in advance,
		// the shouldPreBuffer decision is based upon whether the returned value would fit
		// in the current buffer without requiring a resize of the buffer.
		// 
		// This is because, in all likelyhood, the amount read from the socket will be less than the default value.
		// Thus we should avoid over-allocating the read buffer when we can simply use the pre-buffer instead.
		
        
		if (shouldPreBufferPtr)
		{
            // Gets the buffer size
			NSUInteger buffSize = [buffer length];
            
            // Get the amount of the buffer which has been utilized
			NSUInteger buffUsed = startOffset + bytesDone;
			
            // Gets the amount of available space in the bufer
			NSUInteger buffSpace = buffSize - buffUsed;
			
            
			if (buffSpace >= result)
            {
				*shouldPreBufferPtr = NO;
			}else{
				*shouldPreBufferPtr = YES;
            }
		}
	}
	
	return result;
}

/**
 * For read packets without a set terminator, returns the amount of data
 * that can be read without exceeding the readLength or maxLength.
 * 
 * The given parameter indicates the number of bytes estimated to be available on the socket,
 * which is taken into consideration during the calculation.
 * 
 * The given hint MUST be greater than zero.
    param NSUInteger
    returns NSUInteger
**/
- (NSUInteger)readLengthForNonTermWithHint:(NSUInteger)bytesAvailable
{
	NSAssert(term == nil, @"This method does not apply to term reads");
	NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
	
	if (readLength > 0)
	{
		// Read a specific length of data
		
		return MIN(bytesAvailable, (readLength - bytesDone));
		
		// No need to avoid resizing the buffer.
		// If the user provided their own buffer,
		// and told us to read a certain length of data that exceeds the size of the buffer,
		// then it is clear that our code will resize the buffer during the read operation.
		// 
		// This method does not actually do any resizing.
		// The resizing will happen elsewhere if needed.
	}
	else
	{
		// Read all available data
		
		NSUInteger result = bytesAvailable;
		
		if (maxLength > 0)
		{
            // Get the lesser of the bytes available, or the maximum length minus the bytesDone reading or writing
			result = MIN(result, (maxLength - bytesDone));
		}
		
		// No need to avoid resizing the buffer.
		// If the user provided their own buffer,
		// and told us to read all available data without giving us a maxLength,
		// then it is clear that our code might resize the buffer during the read operation.
		// 
		// This method does not actually do any resizing.
		// The resizing will happen elsewhere if needed.
		
		return result;
	}
}

/**
    For read packets with a set terminator, returns the amount of data that can be read without exceeding the maxLength.
 
    The given parameter indicates the number of bytes estimated to be available on the socket, which is taken into consideration during the calculation.

    To optimize memory allocations, mem copies, and mem moves the shouldPreBuffer boolean value will indicate if the data should be read into a prebuffer first, or if the data can be read directly into the read packet's buffer.
    param NSUInteger
    param BOOL
    returns NSUInteger
 
**/
- (NSUInteger)readLengthForTermWithHint:(NSUInteger)bytesAvailable shouldPreBuffer:(BOOL *)shouldPreBufferPtr
{
    // Test whether the terminator is not nil
	NSAssert(term != nil, @"This method does not apply to non-term reads");
    
    // Test whether there are bytes available to read
	NSAssert(bytesAvailable > 0, @"Invalid parameter: bytesAvailable");
	
	
	NSUInteger result = bytesAvailable;
	
	if (maxLength > 0)
	{
		result = MIN(result, (maxLength - bytesDone));
	}
	
	// Should the data be read into the read packet's buffer, or into a pre-buffer first?
	// 
	// One would imagine the preferred option is the faster one.
	// So which one is faster?
	// 
	// Reading directly into the packet's buffer requires:
	// 1. Possibly resizing packet buffer (malloc/realloc)
	// 2. Filling buffer (read)
	// 3. Searching for term (memcmp)
	// 4. Possibly copying overflow into prebuffer (malloc/realloc, memcpy)
	// 
	// Reading into prebuffer first:
	// 1. Possibly resizing prebuffer (malloc/realloc)
	// 2. Filling buffer (read)
	// 3. Searching for term (memcmp)
	// 4. Copying underflow into packet buffer (malloc/realloc, memcpy)
	// 5. Removing underflow from prebuffer (memmove)
	// 
	// Comparing the performance of the two we can see that reading
	// data into the prebuffer first is slower due to the extra memove.
	// 
	// However:
	// The implementation of NSMutableData is open source via core foundation's CFMutableData.
	// Decreasing the length of a mutable data object doesn't cause a realloc.
	// In other words, the capacity of a mutable data object can grow, but doesn't shrink.
	// 
	// This means the prebuffer will rarely need a realloc.
	// The packet buffer, on the other hand, may often need a realloc.
	// This is especially true if we are the buffer owner.
	// Furthermore, if we are constantly realloc'ing the packet buffer,
	// and then moving the overflow into the prebuffer,
	// then we're consistently over-allocating memory for each term read.
	// And now we get into a bit of a tradeoff between speed and memory utilization.
	// 
	// The end result is that the two perform very similarly.
	// And we can answer the original question very simply by another means.
	// 
	// If we can read all the data directly into the packet's buffer without resizing it first,
	// then we do so. Otherwise we use the prebuffer.
	
	if (shouldPreBufferPtr)
	{
		NSUInteger buffSize = [buffer length];
		NSUInteger buffUsed = startOffset + bytesDone;
		
		if ((buffSize - buffUsed) >= result)
        {
			*shouldPreBufferPtr = NO;
		}else{
			*shouldPreBufferPtr = YES;
        }
	}
	
	return result;
}

/**
    For read packets with a set terminator,returns the amount of data that can be read from the given preBuffer,without going over a terminator or the maxLength.
 
    It is assumed the terminator has not already been read.
 
    param NSData
    param BOOL
    returns NSUInteger
**/
- (NSUInteger)readLengthForTermWithPreBuffer:(NSData *)preBuffer found:(BOOL *)foundPtr
{
    // Test whether the terminator is not nil
	NSAssert(term != nil, @"This method does not apply to non-term reads");
    
    // Test whether the prebuffer length is greater than zero
	NSAssert([preBuffer length] > 0, @"Invoked with empty pre buffer!");
	
	// We know that the terminator, as a whole, doesn't exist in our own buffer.
	// But it is possible that a portion of it exists in our buffer.
	// So we're going to look for the terminator starting with a portion of our own buffer.
	// 
	// Example:
	// 
	// term length      = 3 bytes
	// bytesDone        = 5 bytes
	// preBuffer length = 5 bytes
	// 
	// If we append the preBuffer to our buffer,
	// it would look like this:
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------------------
	// 
	// So we start our search here:
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// -------^-^-^---------
	// 
	// And move forwards...
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------^-^-^-------
	// 
	// Until we find the terminator or reach the end.
	// 
	// ---------------------
	// |B|B|B|B|B|P|P|P|P|P|
	// ---------------^-^-^-
	
	BOOL found = NO;
	
    // Get the length of the terminator
	NSUInteger termLength = [term length];
    
    // Get the preBuffer length
	NSUInteger preBufferLength = [preBuffer length];
	
    
    // Check if the bytes done plus prebuffer lengh is less than the 
    // termination length
	if ((bytesDone + preBufferLength) < termLength)
	{
		// Not enough data for a full term sequence yet
		return preBufferLength;
	}
	
    
    // Maximum prebuffer length
	NSUInteger maxPreBufferLength;
    
    // If the maximum prebuffer length is greater than zero
	if (maxLength > 0) {
		maxPreBufferLength = MIN(preBufferLength, (maxLength - bytesDone));
		
		// Note: maxLength >= termLength
	}
    // If the maximum prebuffer length is equal to or less than zero
	else {
		maxPreBufferLength = preBufferLength;
	}
	
    
	Byte seq[termLength];
    
    // Create a constant read only local attribute
	const void *termBuf = [term bytes];
	
    
    // Buffer length
	NSUInteger bufLen = MIN(bytesDone, (termLength - 1));
	void *buf = [buffer mutableBytes] + startOffset + bytesDone - bufLen;
	
    
    // Prebuffer length
	NSUInteger preLen = termLength - bufLen;
	void *pre = (void *)[preBuffer bytes];
	
    // Set the loop count for searching through the buffer and prebuffer
	NSUInteger loopCount = bufLen + maxPreBufferLength - termLength + 1; // Plus one. See example above.
	
    
    // Prebuffer length
	NSUInteger result = preBufferLength;
	
    
	NSUInteger i;
	for (i = 0; i < loopCount; i++)
	{
		if (bufLen > 0)
		{
			// Combining bytes from buffer and preBuffer
			
            // Copies bufLen bytes from the bufer to the seq
			memcpy(seq, buf, bufLen);
            
            // Copies preLen bytes from pre to seq plus bufLen
			memcpy(seq + bufLen, pre, preLen);
			
            // compare bytes in memory
			if (memcmp(seq, termBuf, termLength) == 0)
			{
				result = preLen;
				found = YES;
				break;
			}
			
			buf++;
			bufLen--;
			preLen++;
		}
		else // if buffer length is not greater than zero
		{
			// Comparing directly from preBuffer
			
			if (memcmp(pre, termBuf, termLength) == 0)
			{
				NSUInteger preOffset = pre - [preBuffer bytes]; // pointer arithmetic
				
				result = preOffset + termLength;
				found = YES;
				break;
			}
			
			pre++;
		}
	}
	
	// There is no need to avoid resizing the buffer in this particular situation.
	
	if (foundPtr) 
    {
        *foundPtr = found;
    }
    
	return result;
}

/**

    For read packets with a set terminator, scans the packet buffer for the term.

    It is assumed the terminator had not been fully read prior to the new bytes.
 
    If the term is found, the number of excess bytes after the term are returned.

    If the term is not found, this method will return -1.

    Note: A return value of zero means the term was found at the very en.
 
    Prerequisites:
        The given number of bytes have been added to the end of our buffer.
        Our bytesDone variable has NOT been changed due to the prebuffered bytes.
 
    param ssize_t
    returns NSInteger
**/
- (NSInteger)searchForTermAfterPreBuffering:(ssize_t)numBytes
{
    // Test whether the terminator is not nil
	NSAssert(term != nil, @"This method does not apply to non-term reads");
	
	// The implementation of this method is very similar to the above method.
	// See the above method for a discussion of the algorithm used here.
	
	void *buff = [buffer mutableBytes];
	NSUInteger buffLength = bytesDone + numBytes;
	
    // Create a constant read only local attribute
	const void *termBuff = [term bytes];
	NSUInteger termLength = [term length];
	
	// Note: We are dealing with unsigned integers,
	// so make sure the math doesn't go below zero.
	
	NSUInteger i = ((buffLength - numBytes) >= termLength) ? (buffLength - numBytes - termLength + 1) : 0;
	
    // While the terimination length is less than or equal to the buffer length
	while (i + termLength <= buffLength)
	{
        
		void *subBuffer = buff + startOffset + i;
		
        // compare bytes in memory
		if (memcmp(subBuffer, termBuff, termLength) == 0)
		{
			return buffLength - (i + termLength);
		}
		
		i++;
	}
	
	return -1;
}


/*
    Standard deconstructor
*/
- (void)dealloc
{
	[buffer release];
	[term release];
	[super dealloc];
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncWritePacket encompasses the instructions for any given write.
**/
@interface GCDAsyncWritePacket : NSObject
{
  @public
	NSData *buffer; // write buffer
	NSUInteger bytesDone; // bytes done writing
	long tag;
	NSTimeInterval timeout; // the timeout value for writing to a host
}

/*
    Initialize the GCDAsyncWritePacket with timeout ang tag

    param NSData
    param NSTimeInterval
    param long
    returns self
*/
- (id)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i;
@end

@implementation GCDAsyncWritePacket


/*
 
    Initialize the GCDAsyncWritePacket with timeout ang tag
    returns self
 
    param NSData
    param NSTimeInterval
    param long
    returns self
*/
- (id)initWithData:(NSData *)d timeout:(NSTimeInterval)t tag:(long)i
{
	if((self = [super init]))
	{
		buffer = [d retain];
		bytesDone = 0;
		timeout = t;
		tag = i;
	}
	return self;
}

/*
    Standard deconstructor
 */
- (void)dealloc
{
	[buffer release];
	[super dealloc];
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * The GCDAsyncSpecialPacket encompasses special instructions for interruptions in the read/write queues.
 * This class my be altered to support more than just TLS (Transport Layer Security) in the future.
**/
@interface GCDAsyncSpecialPacket : NSObject
{
  @public
	NSDictionary *tlsSettings; // Transport Layer Security settings
}

/*
    Initialize the GCDAsyncSpecial packet with settings
    returns self
 
    param NSDictionary
    returns self
*/
- (id)initWithTLSSettings:(NSDictionary *)settings;

@end

@implementation GCDAsyncSpecialPacket


/*
    Initialize the GCDAsyncSpecial packet with settings
 
    param NSDictionary
    returns self
 */
- (id)initWithTLSSettings:(NSDictionary *)settings
{
	if((self = [super init]))
	{
		tlsSettings = [settings copy];
	}
	return self;
}

/*
    Standard deconstructor
 */
- (void)dealloc
{
	[tlsSettings release];
	[super dealloc];
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation GCDAsyncSocket

/*
    Initialize the GCDAsyncSocket
    This message initializes the receiver, setting the delegate at the same time.
    returns self (instance of GCDAsyncSocket)
 */
- (id)init
{
	return [self initWithDelegate:nil delegateQueue:NULL socketQueue:NULL];
}

/*
    Initialize the GCDAsyncSocket with a socket queue
 
    param dispatch_queue_t
    returns self (instance of GCDAsyncSocket)
 */
- (id)initWithSocketQueue:(dispatch_queue_t)sq
{
    
    // This message initializes the receiver, setting the delegate at the same time.
	return [self initWithDelegate:nil delegateQueue:NULL socketQueue:sq];
}

/*
    Initialize the GCDAsyncSocket with delegate and delegate queue
    This message initializes the receiver, setting the delegate at the same time.
 
    param id
    param dispatch_queue_t
    returns self (instance of GCDAsyncSocket)
 */
- (id)initWithDelegate:(id)aDelegate delegateQueue:(dispatch_queue_t)dq
{
	return [self initWithDelegate:aDelegate delegateQueue:dq socketQueue:NULL];
}

/*
    Initialize the GCDAsyncSocket with delegate, delegate queue, and socket queue
    This message initializes the receiver, setting the delegate at the same time.
 
    param id
    param dispatch_queue_t
    param dispatch_queue_t
    returns self (instance of GCDAsyncSocket)
 */
- (id)initWithDelegate:(id)aDelegate delegateQueue:(dispatch_queue_t)dq socketQueue:(dispatch_queue_t)sq
{
	if((self = [super init]))
	{
		delegate = aDelegate;
		
        // Test if there is a delegat queue
		if (dq)
		{
            // Increment the reference count of the delegate queue
			dispatch_retain(dq);
			delegateQueue = dq;
		}
		
		socket4FD = SOCKET_NULL;
		socket6FD = SOCKET_NULL;
		connectIndex = 0;
		
		if (sq) // socket queue
		{
            // Make sure the socket queue is not a global concurrence queue
			NSString *assertMsg = @"The given socketQueue parameter must not be a concurrent queue.";
			
            
            // Test whether the socket queue is not equal to the global queue values
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), assertMsg);
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), assertMsg);
			NSAssert(sq != dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), assertMsg);
			
			dispatch_retain(sq);  // Increments the reference to socket queue
			socketQueue = sq;
		}
		else  // if there isn't a socket queue, then create one
		{
            // Creates the Grand Central Dispatch AsyncSocket queue
			socketQueue = dispatch_queue_create("GCDAsyncSocket", NULL);
		}
		
        // Create readqueue mutable array with capacity of 5
		readQueue = [[NSMutableArray alloc] initWithCapacity:5];
		currentRead = nil;
		
        // Create writequeue mutable array with capacity of 5
		writeQueue = [[NSMutableArray alloc] initWithCapacity:5];
		currentWrite = nil;
		
        // Create partial read buffer
		partialReadBuffer = [[NSMutableData alloc] init];
	}
	return self;
}

/*
    Standard deconstructor
 */
- (void)dealloc
{
	LogInfo(@"%@ - %@ (start)", THIS_METHOD, self);
	
    
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
	{
		[self closeWithError:nil];
	}
	else // if currently executing block is not running on socket queue
	{
		dispatch_sync(socketQueue, ^{
			[self closeWithError:nil];
		});
	}
	
	delegate = nil;
    
    // If there is a delegate queue than release it
	if (delegateQueue)
    {
		dispatch_release(delegateQueue);
    }
    
    
	delegateQueue = NULL;
	
	dispatch_release(socketQueue);
	socketQueue = NULL;
	
    // Release the read and write queue
	[readQueue release];
	[writeQueue release];
	
	[partialReadBuffer release];
	
#if !TARGET_OS_IPHONE
	[sslReadBuffer release];
#endif
	
	[userData release];
	
	LogInfo(@"%@ - %@ (finish)", THIS_METHOD, self);
	
	[super dealloc];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Configuration
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


/*
    Gets the delegate
    returns id
 */
- (id)delegate
{
    
    // Returns the queue on which the currently executing block is running
    // In this case, is the block running on the socketQueue
	if (dispatch_get_current_queue() == socketQueue)
	{
		return delegate;
	}
	else // If block not running on the socket queue then submit to dispatch queue
	{
        // the result from the executing block
		__block id result;
		
        
        // Submits a block for synchronous execution on the socketQueue
		dispatch_sync(socketQueue, ^{
			result = delegate;
		}); // END OF BLOCK
		
		return result;
	}
}

/*
    Sets the delegate
 
    param id
    param BOOL
*/
- (void)setDelegate:(id)newDelegate synchronously:(BOOL)synchronously
{
    
    // The prototype of blocks submitted to dispatch queues, which 
    // take no arguments and have no return value.
	dispatch_block_t block = ^{
		delegate = newDelegate;
	};
	
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue) {
		block();
	}
	else { // if socketQueue is not currently running the block
		if (synchronously)
        {
            // Run the block synchronously, which means the block executes and control comes back
			dispatch_sync(socketQueue, block);
		}else{
            
            // Runs the block asynchronously, which means the block
            // turns control over to the thread
			dispatch_async(socketQueue, block);
        }
	}
}

/*
    Sets the delegate
 
    param id
*/
- (void)setDelegate:(id)newDelegate
{
    // Sets the delegate as the newDelegate for asynchronous execution of blocks
	[self setDelegate:newDelegate synchronously:NO];
}

/*
    Set the delegate as a new delegate
 
    param id
*/
- (void)synchronouslySetDelegate:(id)newDelegate
{
    // Set the delegate as the newDelegate for synchronous execution of blocks
	[self setDelegate:newDelegate synchronously:YES];
}

/*
    Gets the delegateQueue
    returns dispatch_queue_t
*/
- (dispatch_queue_t)delegateQueue
{
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
	{
		return delegateQueue;
	}
	else // If currently executing block not running on socket queue
	{
        
        // result from the executing block
		__block dispatch_queue_t result;
		
        
        // Submits a block for synchronous execution on the socketQueue
		dispatch_sync(socketQueue, ^{
			result = delegateQueue;
		}); // END OF BLOCK
		
		return result;
	}
}

/*
    Sets the delegate queue
 
    param dispatch_queue_t
    param BOOL
*/
- (void)setDelegateQueue:(dispatch_queue_t)newDelegateQueue synchronously:(BOOL)synchronously
{
    
    // The prototype of blocks submitted to dispatch queues, which take no arguments and have no return value.
	dispatch_block_t block = ^{
		
        // If there is a delegate queue
		if (delegateQueue)
        {
            // Decrement the reference count of the delegateQueue
			dispatch_release(delegateQueue);
        }
        
        // If there is a new delegate queue
		if (newDelegateQueue)
        {
            // Increment the reference count of the newDelegateQueue
			dispatch_retain(newDelegateQueue);
		}
        
		delegateQueue = newDelegateQueue;
	}; // END OF BLOCK
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue) {
		block();
	}
	else { // if the current queue is not the socketQueue
        
        
		if (synchronously)
        {
			dispatch_sync(socketQueue, block);
        }else{ // If executing blocks asynchronously
			dispatch_async(socketQueue, block);
        }
	}
}

/*
    Sets the delegate queue
    param dispatch_queue_t
*/
- (void)setDelegateQueue:(dispatch_queue_t)newDelegateQueue
{
    // Set the delegate queue to the new delegate queue for asynchronous execution of blocks
	[self setDelegateQueue:newDelegateQueue synchronously:NO];
}

/*
    Sets the delegate queue
    param dispatch_queue_t
*/
- (void)synchronouslySetDelegateQueue:(dispatch_queue_t)newDelegateQueue
{
    // Set the delegate queue to the new delegate queue for synchronous execution of blocks
	[self setDelegateQueue:newDelegateQueue synchronously:YES];
}

/*
    Gets the delegate point and delegate queue pointer
    param id
    param dispatch_queue_t
*/
- (void)getDelegate:(id *)delegatePtr delegateQueue:(dispatch_queue_t *)delegateQueuePtr
{
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
	{
        // If there is a delegate pointer
		if (delegatePtr)
        {
            *delegatePtr = delegate;
        }
        
        // If there is a delegateQueue pointer
		if (delegateQueuePtr)
        {
            *delegateQueuePtr = delegateQueue;
        }
        
	}
	else  // If the current queue is not the socketQueue
	{
        // Get the delegate pointer and delegate queue from the block
		__block id dPtr = NULL;
		__block dispatch_queue_t dqPtr = NULL;
		
        
        //BLOCK
        
        // Submits a block for synchronous execution on the socketQueue
		dispatch_sync(socketQueue, ^{
			dPtr = delegate; //delegate pointer
			dqPtr = delegateQueue; // delegate que pointer
		}); // END OF BLOCK
		
        // If there is a delegate pointer
		if (delegatePtr)
        {
            *delegatePtr = dPtr;
        }
        
        // If there is a delegateQueue pointer
		if (delegateQueuePtr)
        {
            *delegateQueuePtr = dqPtr;
        }
	}
}

/*
    Sets the delegate
    param id
    param dispatch_queue_t
    param BOOL
*/
- (void)setDelegate:(id)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue synchronously:(BOOL)synchronously
{
	dispatch_block_t block = ^{
		
		delegate = newDelegate;
		
        // if there is a delegateQueue
		if (delegateQueue)
        {
            // Decrement the reference count of the delegateQueue
			dispatch_release(delegateQueue);
		}
        
        // if there is a newDelegateQueue
		if (newDelegateQueue)
        {
            // Increment the reference count of the newDelegateQueue
			dispatch_retain(newDelegateQueue);
		}
        
        
		delegateQueue = newDelegateQueue;
	};
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue) {
		block();
	}
	else { // if the current queue is not the socketQueue
		if (synchronously)
        {
            // Submits a block for synchronous execution on the socketQueue
			dispatch_sync(socketQueue, block);
		}else{ // if executing asynchronously
            
            // Submits a block for asynchronous execution on the socketQueue
			dispatch_async(socketQueue, block);
        }
	}
}

/*
    Sets the delegate and delegate queue
    param id
    param dispatch_queue_t
*/
- (void)setDelegate:(id)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegate:newDelegate delegateQueue:newDelegateQueue synchronously:NO];
}

/*
    param id
    param dispatch_queue_t
*/
- (void)synchronouslySetDelegate:(id)newDelegate delegateQueue:(dispatch_queue_t)newDelegateQueue
{
	[self setDelegate:newDelegate delegateQueue:newDelegateQueue synchronously:YES];
}

/*
    Whether to automatically disconnect upon closing the read stream
    returns BOOL
*/
- (BOOL)autoDisconnectOnClosedReadStream
{
	// Note: YES means kAllowHalfDuplexConnection is OFF
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
	{
		return ((config & kAllowHalfDuplexConnection) == 0);
	}
	else
	{
        // Gets the result from the block
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
			result = ((config & kAllowHalfDuplexConnection) == 0);
		});
		
		return result;
	}
}

/*
    Sets the flag for whether to automatically disconnect upon closing
    the read stream
    param BOOL
*/
- (void)setAutoDisconnectOnClosedReadStream:(BOOL)flag
{
	// Note: YES means kAllowHalfDuplexConnection is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
        {
			config &= ~kAllowHalfDuplexConnection;
		}else{
			config |= kAllowHalfDuplexConnection;
        }
	};
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_async(socketQueue, block);
    }
}

/*
    Returns whether IP version 4 is enabled
    returns BOOL
*/
- (BOOL)isIPv4Enabled
{
	// Note: YES means kIPv4Disabled is OFF
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
	{
		return ((config & kIPv4Disabled) == 0);
	}
	else
	{
        // Gets the result from the block
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
			result = ((config & kIPv4Disabled) == 0);
		});
		
		return result;
	}
}

/*
    Sets the flag to enable IP version 4
    param BOOL
*/
- (void)setIPv4Enabled:(BOOL)flag
{
	// Note: YES means kIPv4Disabled is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
        {
			config &= ~kIPv4Disabled;
		}else{
			config |= kIPv4Disabled;
        }
	};
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_async(socketQueue, block);
    }
}


/*
    Returns whether IP version 6 is enabled
    returns BOOL
*/
- (BOOL)isIPv6Enabled
{
	// Note: YES means kIPv6Disabled is OFF
	
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
	{
		return ((config & kIPv6Disabled) == 0);
	}
	else
	{
        // Gets the result from the block
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
			result = ((config & kIPv6Disabled) == 0);
		});
		
		return result;
	}
}

/*
    Sets the flag to enable IP version 6
    param BOOL
*/
- (void)setIPv6Enabled:(BOOL)flag
{
	// Note: YES means kIPv6Disabled is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
        {
			config &= ~kIPv6Disabled;
		}else{
			config |= kIPv6Disabled;
        }
	};
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_async(socketQueue, block);
    }
}

/*
    Whether IP version 4 is preferred over IP version 6
    returns BOOL
*/
- (BOOL)isIPv4PreferredOverIPv6
{
	// Note: YES means kPreferIPv6 is OFF
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
	{
		return ((config & kPreferIPv6) == 0);
	}
	else
	{
        // Gets the result from the block
		__block BOOL result;
		
		dispatch_sync(socketQueue, ^{
			result = ((config & kPreferIPv6) == 0);
		});
		
		return result;
	}
}

/*
    Set the flag for whether IP version 4 is preferred over IP version 6
    param BOOL
*/
- (void)setPreferIPv4OverIPv6:(BOOL)flag
{
	// Note: YES means kPreferIPv6 is OFF
	
	dispatch_block_t block = ^{
		
		if (flag)
        {
			config &= ~kPreferIPv6;
		}else{
			config |= kPreferIPv6;
        }
	};
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_async(socketQueue, block);
    }
}


/*
    Gets the userData
    User data allows you to associate arbitrary information with the socket.
    This data is not used internally by socket in any way.
    returns id
*/
- (id)userData
{
    // Gets the result from the block
	__block id result;
	
    
    // The prototype of blocks submitted to dispatch queues, which take no arguments and have no return value.
	dispatch_block_t block = ^{
		
		result = [userData retain];
	}; // END OF BLOCK
	
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_sync(socketQueue, block);
	}
    
    
	return [result autorelease];
}

/*
    Sets userData
    param id
*/
- (void)setUserData:(id)arbitraryUserData
{
    // defines block as a dispatch_block_t type
    // doesn't accept any arguements
	dispatch_block_t block = ^{
		
		if (userData != arbitraryUserData)
		{
			[userData release];
			userData = [arbitraryUserData retain];
		}
	}; //end of block
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
    }else{
		dispatch_async(socketQueue, block);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Accepting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


/*
    Whether accept connection on a port (listen socket)
    port - A port number at which the receiver should accept connections.
    errPtr - The address of an NSError object pointer. In the event of an error, the pointer will be set to the NSError object describing the error
 
    param UInt16
    param NSError
    returns BOOL
*/
- (BOOL)acceptOnPort:(UInt16)port error:(NSError **)errPtr
{
	return [self acceptOnInterface:nil port:port error:errPtr];
}

/*
    Whether accept connection on interface and port
    param NSString
    param UInt16
    returns BOOL
*/
- (BOOL)acceptOnInterface:(NSString *)interface port:(UInt16)port error:(NSError **)errPtr
{
	LogTrace();
	
    // Gets the result from the block
	__block BOOL result = YES;
	__block NSError *err = nil;
	
	// CreateSocket Block
	// This block will be invoked within the dispatch block below.
	// defines a block of createSocket type with accepts int (domain) and NSData (interface address) as arguements
    
	int(^createSocket)(int, NSData*) = ^int (int domain, NSData *interfaceAddr) {
		
        // creates an endpoint for communication and returns a descriptor
		int socketFD = socket(domain, SOCK_STREAM, 0);
		
        
		if (socketFD == SOCKET_NULL)
		{
			NSString *reason = @"Error in socket() function";
			err = [[self errnoErrorWithReason:reason] retain];
			
			return SOCKET_NULL;
		}
		
        
		int status;
		
        /////////////////////////
		// Set socket options
		/////////////////////////
        // file control
        // F_SETFL sets the descriptor flags
        // O_NONBLOCK - Non-blocking I/O; if no data is available to a read
        // call, or if a write operation would block, the read or
        // write call returns -1 with the error EAGAIN.
		status = fcntl(socketFD, F_SETFL, O_NONBLOCK);
		if (status == -1)
		{
			NSString *reason = @"Error enabling non-blocking IO on socket (fcntl)";
			err = [[self errnoErrorWithReason:reason] retain];
			
			close(socketFD);
			return SOCKET_NULL;
		}
		
        
        
		int reuseOn = 1;
        
        // Set the options on a socket
        // SO_REUSEADDR indicates that the rules used in validating
        // addresses supplied in bind(2) call should allow reuse of 
        // local addresses
		status = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
        
        // Check if could set the socket options
		if (status == -1)
		{
			NSString *reason = @"Error enabling address reuse (setsockopt)";
			err = [[self errnoErrorWithReason:reason] retain];
			
			close(socketFD);
			return SOCKET_NULL;
		}
		
        
		// Bind socket
		
		status = bind(socketFD, (struct sockaddr *)[interfaceAddr bytes], (socklen_t)[interfaceAddr length]);
        
        // If could not bind socket
		if (status == -1)
		{
			NSString *reason = @"Error in bind() function";
			err = [[self errnoErrorWithReason:reason] retain];
			
			close(socketFD);
			return SOCKET_NULL;
		}
		
		// Listen
		
        // listen for connections on a socket
		status = listen(socketFD, 1024);
        
        // Check if we can listen to a connection on a socket
		if (status == -1)
		{
			NSString *reason = @"Error in listen() function";
			err = [[self errnoErrorWithReason:reason] retain];
			
			close(socketFD);
			return SOCKET_NULL;
		}
		
		return socketFD;
	};
	
	// Create dispatch block and run on socketQueue
	
	dispatch_block_t block = ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		if (delegate == nil) // Must have delegate set
		{
			result = NO;
			
			NSString *msg = @"Attempting to accept without a delegate. Set a delegate first.";
			err = [[self badConfigError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
		if (delegateQueue == NULL) // Must have delegate queue set
		{
			result = NO;
			
			NSString *msg = @"Attempting to accept without a delegate queue. Set a delegate queue first.";
			err = [[self badConfigError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
        // Whether IP version 4 protocol is disabled
		BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
        
        // Whether IP version 6 protocol is disabled
		BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
		
        // If both IP version 4 and IP version 6 are disabled
		if (isIPv4Disabled && isIPv6Disabled) // Must have IPv4 or IPv6 enabled
		{
			result = NO;
			
			NSString *msg = @"Both IPv4 and IPv6 have been disabled. Must enable at least one protocol first.";
			err = [[self badConfigError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
        
		if (![self isDisconnected]) // Must be disconnected
		{
			result = NO;
			
			NSString *msg = @"Attempting to accept while connected or accepting connections. Disconnect first.";
			err = [[self badConfigError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
		// Clear queues (spurious read/write requests post disconnect)
		[readQueue removeAllObjects];
		[writeQueue removeAllObjects];
		
		// Resolve interface from description
		
		NSData *interface4 = nil;
		NSData *interface6 = nil;
		
        
		[self getInterfaceAddress4:&interface4 address6:&interface6 fromDescription:interface port:port];
		
        
		if ((interface4 == nil) && (interface6 == nil))
		{
			result = NO;
			
			NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
			err = [[self badParamError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
		if (isIPv4Disabled && (interface6 == nil))
		{
			result = NO;
			
			NSString *msg = @"IPv4 has been disabled and specified interface doesn't support IPv6.";
			err = [[self badParamError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
		if (isIPv6Disabled && (interface4 == nil))
		{
			result = NO;
			
			NSString *msg = @"IPv6 has been disabled and specified interface doesn't support IPv4.";
			err = [[self badParamError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
        // Whether IP version 4 protocol is enabled
		BOOL enableIPv4 = !isIPv4Disabled && (interface4 != nil);
        
        // Whether IP version 6 protocol is enabled
		BOOL enableIPv6 = !isIPv6Disabled && (interface6 != nil);
		
		// Create sockets, configure, bind, and listen
		
		if (enableIPv4)
		{
			LogVerbose(@"Creating IPv4 socket");
            
            // Create an internal socket
			socket4FD = createSocket(AF_INET, interface4);
			
			if (socket4FD == SOCKET_NULL)
			{
				result = NO;
				
				[pool drain];
				return_from_block;
			}
		}
		
		if (enableIPv6)
		{
			LogVerbose(@"Creating IPv6 socket");
			
			if (enableIPv4 && (port == 0))
			{
				// No specific port was specified, so we allowed the OS to pick an available port for us.
				// Now we need to make sure the IPv6 socket listens on the same port as the IPv4 socket.
				
				struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)[interface6 bytes];
				addr6->sin6_port = htons([self localPort4]);
			}
			
            // Create an internal socket
			socket6FD = createSocket(AF_INET6, interface6);
			
			if (socket6FD == SOCKET_NULL)
			{
				result = NO;
				
				if (socket4FD != SOCKET_NULL)
				{
					close(socket4FD);
				}
				
				[pool drain];
				return_from_block;
			}
		}
		
		// Create accept sources
		
		if (enableIPv4)
		{
			accept4Source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socket4FD, 0, socketQueue);
			
            
			int socketFD = socket4FD;
			dispatch_source_t acceptSource = accept4Source;
			
            // Sets the event handler block for the accept4Source
			dispatch_source_set_event_handler(accept4Source, ^{
				NSAutoreleasePool *eventPool = [[NSAutoreleasePool alloc] init];
				
				LogVerbose(@"event4Block");
				
				unsigned long i = 0;
				unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
				
				LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
				
				while ([self doAccept:socketFD] && (++i < numPendingConnections));
				
				[eventPool drain];
			}); // END OF BLOCK
			
            
            // Sets the cancellation handler block for the accept4Source
			dispatch_source_set_cancel_handler(accept4Source, ^{
				
				LogVerbose(@"dispatch_release(accept4Source)");
				dispatch_release(acceptSource);
				
				LogVerbose(@"close(socket4FD)");
				close(socketFD);
			}); // END OF BLOCK
			
			LogVerbose(@"dispatch_resume(accept4Source)");
			dispatch_resume(accept4Source); // resumes the accept4Source 
		}
		
		if (enableIPv6)
		{
            // Dispatch sources are used to automatically submit event
            // handler blocks to dispatch queues in response to external 
            // events.
			accept6Source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socket6FD, 0, socketQueue);
			
			int socketFD = socket6FD;
			dispatch_source_t acceptSource = accept6Source;
			
            
            // Sets the event handler block for the accept6Source
			dispatch_source_set_event_handler(accept6Source, ^{
				NSAutoreleasePool *eventPool = [[NSAutoreleasePool alloc] init];
				
				LogVerbose(@"event6Block");
				
				unsigned long i = 0;
				unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
				
				LogVerbose(@"numPendingConnections: %lu", numPendingConnections);
				
				while ([self doAccept:socketFD] && (++i < numPendingConnections));
				
				[eventPool drain];
			}); // END OF BLOCK
			
            
            // Sets the cancellation handler block for the accept6Source
			dispatch_source_set_cancel_handler(accept6Source, ^{
				
				LogVerbose(@"dispatch_release(accept6Source)");
				dispatch_release(acceptSource);
				
				LogVerbose(@"close(socket6FD)");
				close(socketFD);
			}); // END OF BLOCK
			
			LogVerbose(@"dispatch_resume(accept6Source)");
			dispatch_resume(accept6Source);  // resumes the accept for IP version 6 source
		}
		
        // If set, socket has been started (accepting/connecting)
		flags |= kSocketStarted;
		[pool drain];
	};
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_sync(socketQueue, block);
    }
    
    
	if (result == NO)
	{
		LogInfo(@"Error in accept: %@", err);
		
		if (errPtr)
        {
			*errPtr = [err autorelease];
		}else{
			[err release];
        }
	}
	
	return result;
}


/*
    Whether accept for parent socket file description
    param int
    returns BOOL
*/
- (BOOL)doAccept:(int)parentSocketFD
{
	LogTrace();
	
	BOOL isIPv4;
	int childSocketFD;
	NSData *childSocketAddress;
	
    // if the parent socket file description is IP version 4
	if (parentSocketFD == socket4FD)
	{
		isIPv4 = YES;
		
        
		struct sockaddr_in addr; // the IP version 4 address
		socklen_t addrLen = sizeof(addr); // gets the length of the address
	
        // accept a new connection on a socket
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		
        // Check whether there was an error accepting
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		
        // Sets the child socket address
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	else // if (parentSocketFD == socket6FD)
	{
		isIPv4 = NO;  
		
		struct sockaddr_in6 addr; // the IP version 4 address
		socklen_t addrLen = sizeof(addr);  // gets the length of the address

		// accept a new connection on a socket
		childSocketFD = accept(parentSocketFD, (struct sockaddr *)&addr, &addrLen);
		
        // Check if there was an error accepting
		if (childSocketFD == -1)
		{
			LogWarn(@"Accept failed with error: %@", [self errnoError]);
			return NO;
		}
		
        // Sets the child socket address
		childSocketAddress = [NSData dataWithBytes:&addr length:addrLen];
	}
	
	// Enable non-blocking IO on the socket
	
	int result = fcntl(childSocketFD, F_SETFL, O_NONBLOCK);
	if (result == -1)
	{
		LogWarn(@"Error enabling non-blocking IO on accepted socket (fcntl)");
		return NO;
	}
	
	// Prevent SIGPIPE signals
	
	int nosigpipe = 1;
	setsockopt(childSocketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
	
    
	// Notify delegate
	
    
    // if there is a delegateQueue
	if (delegateQueue)
	{
        // Get the delegate
		id theDelegate = delegate;
		
        // Executes the block asynchronously
		dispatch_async(delegateQueue, ^{
            
            // Setup an autorelease pool
			NSAutoreleasePool *delegatePool = [[NSAutoreleasePool alloc] init];
			
			// Query delegate for custom socket queue
			
			dispatch_queue_t childSocketQueue = NULL;
			
            
            // Check if the delegate has the method
            // newSocketQueueForConnectionFromAddress
			if ([theDelegate respondsToSelector:@selector(newSocketQueueForConnectionFromAddress:onSocket:)])
			{
                // Creates a new socket
				childSocketQueue = [theDelegate newSocketQueueForConnectionFromAddress:childSocketAddress onSocket:self];
			}
			
			// Create GCDAsyncSocket instance for accepted socket
			
			GCDAsyncSocket *acceptedSocket = [[GCDAsyncSocket alloc] initWithDelegate:delegate
                    delegateQueue:delegateQueue
                    socketQueue:childSocketQueue];
			
            // If using IP version 4 protocol
			if (isIPv4)
            {
				acceptedSocket->socket4FD = childSocketFD;
			}else{ // If using IP version 6 protocol
				acceptedSocket->socket6FD = childSocketFD;
            }
			
			acceptedSocket->flags = (kSocketStarted | kConnected);
			
			// Setup read and write sources for accepted socket
			
            // Executes the block asynchronously
			dispatch_async(acceptedSocket->socketQueue, ^{
				NSAutoreleasePool *socketPool = [[NSAutoreleasePool alloc] init];
				
				[acceptedSocket setupReadAndWriteSourcesForNewlyConnectedSocket:childSocketFD];
				
				[socketPool drain];
			});  // END OF BLOCK
            
			
			// Notify delegate
			
			if ([theDelegate respondsToSelector:@selector(socket:didAcceptNewSocket:)])
			{
                // socket sends this message to provide the receiver with a chance to save a new socket in an appropriate place.
				[theDelegate socket:self didAcceptNewSocket:acceptedSocket];
			}
			
			// Release the socket queue returned from the delegate (it was retained by acceptedSocket)
			if (childSocketQueue)
            {
				dispatch_release(childSocketQueue);
            }
			
			// Release the accepted socket (it should have been retained by the delegate)
			[acceptedSocket release];
			
            
			[delegatePool drain];
		}); // End of block
	}
	
	return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Connecting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
    This method runs through the various checks required prior to a connection attempt.
 
    It is shared between the connectToHost and connectToAddress methods.
    param NSString
    param NSError
    returns BOOL
**/
- (BOOL)preConnectWithInterface:(NSString *)interface error:(NSError **)errPtr
{
    
    // Test whether the socketQueue is the current queue
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Exectued on wrong dispatch queue");
	
    // Test whether delegate is nil
	if (delegate == nil) // Must have delegate set
	{
        
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate. Set a delegate first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
    // Test whether there is a delegateQueue
	if (delegateQueue == NULL) // Must have delegate queue set
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect without a delegate queue. Set a delegate queue first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
    // Test whether not disconnected
	if (![self isDisconnected]) // Must be disconnected
	{
		if (errPtr)
		{
			NSString *msg = @"Attempting to connect while connected or accepting connections. Disconnect first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
    // Whether IP version 4 or 6 is disabled
	BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
	BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
	
    
    // Test whether IP version 4 or 6 is disabled.  One or the other should be enabled
	if (isIPv4Disabled && isIPv6Disabled) // Must have IPv4 or IPv6 enabled
	{
		if (errPtr)
		{
			NSString *msg = @"Both IPv4 and IPv6 have been disabled. Must enable at least one protocol first.";
			*errPtr = [self badConfigError:msg];
		}
		return NO;
	}
	
    // Check that there is an interface
	if (interface)  // this is an NSString passed into this method
	{
        // Create local variables
		NSData *interface4 = nil;
		NSData *interface6 = nil;
		
        // Get the IP version 4 and 6 interface based on the passed-in interface description with a port of zero
		[self getInterfaceAddress4:&interface4 address6:&interface6 fromDescription:interface port:0];
		
        
        // Test whether we have gotten and interface based on the interface description or not
		if ((interface4 == nil) && (interface6 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"Unknown interface. Specify valid interface by name (e.g. \"en1\") or IP address.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
        // If IP version 4 is disabled and the interface for IP version 6 is nil.  This means we are suppose to use IP version 6, but there is no interface for IP version 6.  Thus, throw an error
		if (isIPv4Disabled && (interface6 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"IPv4 has been disabled and specified interface doesn't support IPv6.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
        // If IP version 6 is disabled and the interface for IP version 4 is nil.  This means we are suppose to use IP version 4, but there is no interface for IP version 4.  Thus, throw an error.
		if (isIPv6Disabled && (interface4 == nil))
		{
			if (errPtr)
			{
				NSString *msg = @"IPv6 has been disabled and specified interface doesn't support IPv4.";
				*errPtr = [self badParamError:msg];
			}
			return NO;
		}
		
        // If we have made it this far in the method, then we should have the correct settings, and the interfaces.  Thus, retain the interface.
		connectInterface4 = [interface4 retain];
		connectInterface6 = [interface6 retain];
	}
	
	// Clear queues (spurious read/write requests post disconnect)
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
	return YES;
}


/*
    Whether can connect to a host on a particular port
    host - A DNS name or IP address to which the receiver should connect. Both IPv4 and IPv6 addresses are supported.
    port - A port number to which the receiver should connect.
    errPtr - The address of an NSError object pointer. In the event of an error, the pointer will be set to the NSError object describing the error.
 
    param NSString
    param UInt16
    param NSError
    returns BOOL
*/
- (BOOL)connectToHost:(NSString*)host onPort:(UInt16)port error:(NSError **)errPtr
{
    
	return [self connectToHost:host onPort:port withTimeout:-1 error:errPtr];
}


/*
    Whether can connect to host on a specific port via a specific
    interface with a specific timeout
 
    param NSString
    param UInt16
    param NSTimeInterval
    param NSError
    returns BOOL
*/
- (BOOL)connectToHost:(NSString *)host
               onPort:(UInt16)port
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr
{
	return [self connectToHost:host onPort:port viaInterface:nil withTimeout:timeout error:errPtr];
}


/*
    Whether can connect to host on specific port via a specific
    interface
    hostname - A DNS name or IP address to which the receiver should connect. Both IPv4 and IPv6 addresses are supported
    port - A port number to which the receiver should connect.
    errPtr - The address of an NSError object pointer. In the event of an error, the pointer will be set to the NSError object describing the error
 
    param NSString
    param UInt16
    param NSString
    param NSTimeInterval
    param NSError
    returns BOOL
*/
- (BOOL)connectToHost:(NSString *)host
               onPort:(UInt16)port
         viaInterface:(NSString *)interface
          withTimeout:(NSTimeInterval)timeout
                error:(NSError **)errPtr;
{
	LogTrace();
	
    // Gets the result from the block
	__block BOOL result = YES;
	__block NSError *err = nil;
	
    
	dispatch_block_t block = ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		result = [self preConnectWithInterface:interface error:&err];
		if (!result)
		{
			[err retain];
			[pool drain];
			return_from_block;
		}
		
		// We've made it past all the checks.
		// It's time to start the connection process.
		
		flags |= kSocketStarted;
		
		LogVerbose(@"Dispatching DNS lookup...");
		
		// It's possible that the given host parameter is actually a NSMutableString.
		// So we want to copy it now, within this block that will be executed synchronously.
		// This way the asynchronous lookup block below doesn't have to worry about it changing.
		
		int aConnectIndex = connectIndex;
		NSString *hostCpy = [[host copy] autorelease];
		
        // Sets the global concurrent queue
		dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        
        
        // Executes the block on the global concurrent queue
		dispatch_async(globalConcurrentQueue, ^{
			NSAutoreleasePool *lookupPool = [[NSAutoreleasePool alloc] init];
			
			[self lookup:aConnectIndex host:hostCpy port:port];
			
			[lookupPool drain];
		}); // END OF BLOCK
		
        
        
		[self startConnectTimeout:timeout];
		
		[pool drain];
	};
	
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
		block();
	else
		dispatch_sync(socketQueue, block);
	
	if (result == NO)
	{
		if (errPtr)
        {
			*errPtr = [err autorelease];
		}else{
			[err release];
        }
	}
	
	return result;
}

/*
    Whether can connect to a remote address
 
    param NSData
    param NSError
    returns BOOL
*/
- (BOOL)connectToAddress:(NSData *)remoteAddr error:(NSError **)errPtr
{
	return [self connectToAddress:remoteAddr viaInterface:nil withTimeout:-1 error:errPtr];
}


/*
    Whether can connect to a remote address
 
    param NSData
    param NSTimeInterval
    param NSError
    returns BOOL
*/
- (BOOL)connectToAddress:(NSData *)remoteAddr withTimeout:(NSTimeInterval)timeout error:(NSError **)errPtr
{
	return [self connectToAddress:remoteAddr viaInterface:nil withTimeout:timeout error:errPtr];
}


/*
    Whether can connect to remote address via a specific port
 
    param NSData
    param NSString
    param NSTimeInterval
    param NSError
    returns BOOL
*/
- (BOOL)connectToAddress:(NSData *)remoteAddr
            viaInterface:(NSString *)interface
             withTimeout:(NSTimeInterval)timeout
                   error:(NSError **)errPtr
{
	LogTrace();
	
    // Gets the result from the block
	__block BOOL result = YES;
	__block NSError *err = nil;
	
    
    // The prototype of blocks submitted to dispatch queues, which take no arguments and have no return value.
	dispatch_block_t block = ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		// Check for problems with remoteAddr parameter
		
		NSData *address4 = nil;
		NSData *address6 = nil;
		
		if ([remoteAddr length] >= sizeof(struct sockaddr))
		{
			struct sockaddr *sockaddr = (struct sockaddr *)[remoteAddr bytes];
			
            
            // Check if socket is an internal socket
			if (sockaddr->sa_family == AF_INET)
			{
				if ([remoteAddr length] == sizeof(struct sockaddr_in))
				{
					address4 = remoteAddr;
				}
			}
            
            // Check if the socket is an internal socket using IP version 6
			else if (sockaddr->sa_family == AF_INET6)
			{
				if ([remoteAddr length] == sizeof(struct sockaddr_in6))
				{
					address6 = remoteAddr;
				}
			}
		}
		
		if ((address4 == nil) && (address6 == nil))
		{
			NSString *msg = @"A valid IPv4 or IPv6 address was not given";
			err = [[self badParamError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
		BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
		BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
		
		if (isIPv4Disabled && (address4 != nil))
		{
			NSString *msg = @"IPv4 has been disabled and an IPv4 address was passed.";
			err = [[self badParamError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
		if (isIPv6Disabled && (address6 != nil))
		{
			NSString *msg = @"IPv6 has been disabled and an IPv6 address was passed.";
			err = [[self badParamError:msg] retain];
			
			[pool drain];
			return_from_block;
		}
		
		// Run through standard pre-connect checks
		
		result = [self preConnectWithInterface:interface error:&err];
		if (!result)
		{
			[err retain];
			[pool drain];
			return_from_block;
		}
		
		// We've made it past all the checks.
		// It's time to start the connection process.
		
		if (![self connectWithAddress4:address4 address6:address6 error:&err])
		{
			[err retain];
			[pool drain];
			return_from_block;
		}
		
		flags |= kSocketStarted;
		
		[self startConnectTimeout:timeout];
		
		[pool drain];
	};
	
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_sync(socketQueue, block);
	}
    
	if (result == NO)
	{
		if (errPtr)
        {
			*errPtr = [err autorelease];
		}else{
			[err release];
        }
	}
	
	return result;
}

/*
    param int
    param NSString
    param UInt16
*/
- (void)lookup:(int)aConnectIndex host:(NSString *)host port:(UInt16)port
{
	LogTrace();
	
	// This method is executed on a global concurrent queue.
	// It posts the results back to the socket queue.
	// The lookupIndex is used to ignore the results if the connect operation was cancelled or timed out.
	
	NSError *error = nil;
	
	NSData *address4 = nil;
	NSData *address6 = nil;
	
	// Check if the host is the local host or a loopback
	if ([host isEqualToString:@"localhost"] || [host isEqualToString:@"loopback"])
	{
		// Use LOOPBACK address
		struct sockaddr_in nativeAddr;
		nativeAddr.sin_len         = sizeof(struct sockaddr_in);
		nativeAddr.sin_family      = AF_INET;  // Internal socket address family
		nativeAddr.sin_port        = htons(port);
		nativeAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		memset(&(nativeAddr.sin_zero), 0, sizeof(nativeAddr.sin_zero));
		
		struct sockaddr_in6 nativeAddr6;
		nativeAddr6.sin6_len       = sizeof(struct sockaddr_in6);
		nativeAddr6.sin6_family    = AF_INET6; // Internal socket address family
		nativeAddr6.sin6_port      = htons(port);
		nativeAddr6.sin6_flowinfo  = 0;
		nativeAddr6.sin6_addr      = in6addr_loopback;
		nativeAddr6.sin6_scope_id  = 0;
		
		// Wrap the native address structures
		address4 = [NSData dataWithBytes:&nativeAddr length:sizeof(nativeAddr)];
		address6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
	}
	else // If not a localhost or loopback
	{
        
        // Create a string with 'u' and the post number
		NSString *portStr = [NSString stringWithFormat:@"%hu", port];
		
        
		struct addrinfo hints, *res, *res0;
		
        // Fills a block of memory with the size of hints, address of hints, to value of zero
		memset(&hints, 0, sizeof(hints));
        
        // Set the address family as unspecified
		hints.ai_family   = PF_UNSPEC;
        
        // Set the socket type as a stream
		hints.ai_socktype = SOCK_STREAM;
        
        // Set the protocol as unspecified
		hints.ai_protocol = IPPROTO_TCP;
		
        // Get address information error
		int gai_error = getaddrinfo([host UTF8String], [portStr UTF8String], &hints, &res0);
		
        // If there is an error getting the human-readable text string representing hostnames into a dynamicall allocated linked list of struct addrinfo structures.
		if (gai_error)
		{
			error = [self gaiError:gai_error];
		}
		else // If there as not an error getting the address information
		{
            
			for(res = res0; res; res = res->ai_next)
			{
                // Check if an internal socket
				if ((address4 == nil) && (res->ai_family == AF_INET))
				{
					// Found IPv4 address
					// Wrap the native address structure
					address4 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
				}
                
                // Check if an internal socket
				else if ((address6 == nil) && (res->ai_family == AF_INET6))
				{
					// Found IPv6 address
					// Wrap the native address structure
					address6 = [NSData dataWithBytes:res->ai_addr length:res->ai_addrlen];
				}
			}
            
            // Frees the res0 address information structure
			freeaddrinfo(res0);
			
            // If the address is nil then throw an error
			if ((address4 == nil) && (address6 == nil))
			{
				error = [self gaiError:EAI_FAIL];
			}
		}
	}
	
	if (error)
	{
        // Executes block asynchronously
		dispatch_async(socketQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			[self lookup:aConnectIndex didFail:error];
			[pool drain];
		}); // END OF BLOCK
	}
	else // if there is not an error
	{
        // Execute block asynchronously
		dispatch_async(socketQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			[self lookup:aConnectIndex didSucceedWithAddress4:address4 address6:address6];
			[pool drain];
		}); // END OF BLOCK
	}
}


/*
    param int
    param NSData
    param NSData
*/
- (void)lookup:(int)aConnectIndex didSucceedWithAddress4:(NSData *)address4 address6:(NSData *)address6
{
	LogTrace();
	
    // Test whether the current queue is the socketQueue
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Exectued on wrong dispatch queue");
    
    // Test whether there is an IP 4 or 6 address
	NSAssert(address4 || address6, @"Expected at least one valid address");
	
    
	if (aConnectIndex != connectIndex)
	{
		LogInfo(@"Ignoring lookupDidSucceed, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
	// Check for problems
	
	BOOL isIPv4Disabled = (config & kIPv4Disabled) ? YES : NO;
	BOOL isIPv6Disabled = (config & kIPv6Disabled) ? YES : NO;
	
    
    // Check if IP version 4 is disabled and address for IP version 6 is nil.  This should not happen because if IP version 4 is disabled, then it means we are using IP version 6.  However, the address for IP version 6 is nil, so throw an error.
	if (isIPv4Disabled && (address6 == nil))
	{
		NSString *msg = @"IPv4 has been disabled and DNS lookup found no IPv6 address.";
		
        // Close the socket with an error
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
    // Check if IP version 6 is disabled and address for IP version 4 is nil.  This should not happen because if IP version 6 is disabled, then it means we are using IP version 4.  However, the address for IP version 4 is nil, so throw an error.
	if (isIPv6Disabled && (address4 == nil))
	{
		NSString *msg = @"IPv6 has been disabled and DNS lookup found no IPv4 address.";
		
        // Close the socket with the error message
		[self closeWithError:[self otherError:msg]];
		return;
	}
	
	// Start the normal connection process
	
	NSError *err = nil;
	if (![self connectWithAddress4:address4 address6:address6 error:&err])
	{
        // Close the socket with an error message
		[self closeWithError:err];
	}
}

/**
    This method is called if the DNS lookup fails.
    This method is executed on the socketQueue.
 
    Since the DNS lookup executed synchronously on a global concurrent queue, the original connection request may have already been cancelled or timed-out by the time this method is invoked.
 
    The lookupIndex tells us whether the lookup is still valid or not.
 
    param int
    param NSError
**/
- (void)lookup:(int)aConnectIndex didFail:(NSError *)error
{
	LogTrace();
	
    // Test whether the current queue is the socketQueue
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Exectued on wrong dispatch queue");
	
	
	if (aConnectIndex != connectIndex)
	{
		LogInfo(@"Ignoring lookup:didFail: - already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
	[self endConnectTimeout];
	[self closeWithError:error];
}


/*
    Whether connecting with IP version 4 or 6 address
    param NSData
    param NSData
    param NSError
    returns BOOL
*/
- (BOOL)connectWithAddress4:(NSData *)address4 address6:(NSData *)address6 error:(NSError **)errPtr
{
	LogTrace();
	
    // Test whether the current queue is the socketQueue
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Exectued on wrong dispatch queue");
	
	//////////////////////////
	// Determine socket type
    /////////////////////////
	
    // Whether IP version 6 is the preferred protocol
	BOOL preferIPv6 = (config & kPreferIPv6) ? YES : NO;
	
    // Whether to use IP version 6 protocol or not
	BOOL useIPv6 = ((preferIPv6 && address6) || (address4 == nil));
	
    ////////////////////////
	// Create the socket
	////////////////////////
	int socketFD;
	NSData *address;
	NSData *connectInterface;
	
    // If using IP version 6 protocol
	if (useIPv6)
	{
		LogVerbose(@"Creating IPv6 socket");
		
        // Creates an end point for communications
		socket6FD = socket(AF_INET6, SOCK_STREAM, 0);
		
        
		socketFD = socket6FD;
		address = address6;
		connectInterface = connectInterface6;
	}
	else // If using IP version 4 protocol
	{
		LogVerbose(@"Creating IPv4 socket");
		
        // Creates an end point for communications
		socket4FD = socket(AF_INET, SOCK_STREAM, 0);
		
		socketFD = socket4FD;
		address = address4;
		connectInterface = connectInterface4;
	}
	
    // If there is no end point for the communications
	if (socketFD == SOCKET_NULL)
	{
		if (errPtr)
			*errPtr = [self errnoErrorWithReason:@"Error in socket() function"];
		
		return NO;
	}
	
    // If made it to this point, then there is an end point for the communciations (i.e. socket)
    
    ///////////////////////////////////////////////////////
	// Bind the socket to the desired interface (if needed)
	///////////////////////////////////////////////////////
    
    
	if (connectInterface)
	{
		LogVerbose(@"Binding socket...");
		
        // If the port is greater than zero
		if ([[self class] portFromAddress:connectInterface] > 0)
		{
			// Since we're going to be binding to a specific port,
			// we should turn on reuseaddr to allow us to override sockets in time_wait.
			
			int reuseOn = 1;
            
            // Set options for the socket
			setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseOn, sizeof(reuseOn));
		}
		
        // Gets the socket address
		struct sockaddr *interfaceAddr = (struct sockaddr *)[connectInterface bytes];
		
        // binds the interface address to a socket
		int result = bind(socketFD, interfaceAddr, (socklen_t)[connectInterface length]);

		// Check if there was an error binding the interface to the socket
        if (result != 0)
		{
            
			if (errPtr)
            {
				*errPtr = [self errnoErrorWithReason:@"Error in bind() function"];
			}
			return NO;
		}
	}
	
	// Start the connection process in a background queue
	
	int aConnectIndex = connectIndex;
	
    
	dispatch_queue_t globalConcurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

	// Executes block asynchronously
    dispatch_async(globalConcurrentQueue, ^{
		
        // Tries to initiate a connection on a socket
		int result = connect(socketFD, (const struct sockaddr *)[address bytes], (socklen_t)[address length]);
        
        // If successful in initiating a connection on a socket
		if (result == 0)
		{
            // Executes block asynchronously
			dispatch_async(socketQueue, ^{
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				[self didConnect:aConnectIndex];
				[pool drain];
			}); // END OF BLOCK
		}
		else // If unsuccessful in initiating a connection on a socket
		{
			NSError *error = [self errnoErrorWithReason:@"Error in connect() function"];
			
			dispatch_async(socketQueue, ^{
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				[self didNotConnect:aConnectIndex error:error];
				[pool drain];
			});
		}
	});
	
	LogVerbose(@"Connecting...");
	
	return YES;
}


/*
    Did connect to host on a port
    param int
*/
- (void)didConnect:(int)aConnectIndex
{
	LogTrace();
	
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Must be dispatched on socketQueue");
	
	
	if (aConnectIndex != connectIndex)
	{
		LogInfo(@"Ignoring didConnect, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
    
    // If set, the socket is connected
	flags |= kConnected;
	
	[self endConnectTimeout];
	
	NSString *host = [self connectedHost];
	UInt16 port = [self connectedPort];
	
    // If there is a delegateQueue and the delegate had a socket: didConnectToHost:port: method
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:didConnectToHost:port:)])
	{
        
		id theDelegate = delegate;
		
        // Executes block asynchronously
		dispatch_async(delegateQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			
			[theDelegate socket:self didConnectToHost:host port:port];
			
			[pool drain];
		});
	}
		
	// Get the connected socket
	
	int socketFD = (socket4FD != SOCKET_NULL) ? socket4FD : socket6FD;
	
	// Enable non-blocking IO on the socket
	
    // Set the nonblocking flag. This prevents incompatible access to the socket
	int result = fcntl(socketFD, F_SETFL, O_NONBLOCK);
    
    // If could not enable the nonblocking flag
	if (result == -1)
	{
		NSString *errMsg = @"Error enabling non-blocking IO on socket (fcntl)";
		[self closeWithError:[self otherError:errMsg]];
		
		return;
	}
	
    // This means there was not an error enabling the nonblocking flag on the socket
    
	// Prevent SIGPIPE signals
	
	int nosigpipe = 1;
    
    // Sets the socket options
	setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
	
	// Setup our read/write sources.
	
	[self setupReadAndWriteSourcesForNewlyConnectedSocket:socketFD];
	
	// Dequeue any pending read/write requests
	
	[self maybeDequeueRead];
	[self maybeDequeueWrite];
}

/*
    If did not connect
    param int
    param NSError
*/
- (void)didNotConnect:(int)aConnectIndex error:(NSError *)error
{
	LogTrace();
	
    
    // Returns the queue on which the currently executing block is running.
    // In this case, check if the socketQueue is currently running the block
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Must be dispatched on socketQueue");
	
	
	if (aConnectIndex != connectIndex)
	{
		LogInfo(@"Ignoring didNotConnect, already disconnected");
		
		// The connect operation has been cancelled.
		// That is, socket was disconnected, or connection has already timed out.
		return;
	}
	
	[self endConnectTimeout];
	[self closeWithError:error];
}


/*
    Start the connection timeout
    param NSTimeInterval
*/
- (void)startConnectTimeout:(NSTimeInterval)timeout
{
    // if the timeout is > or equal to zero
	if (timeout >= 0.0)
	{
        
		connectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
        // Sets the event handler block for the connectTimer.
		dispatch_source_set_event_handler(connectTimer, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			
			[self doConnectTimeout];
			
			[pool drain];
		}); // END BLOCK
		
        
		dispatch_source_t theConnectTimer = connectTimer;
        
        // Sets the cancellation handler block for the connectTimer
		dispatch_source_set_cancel_handler(connectTimer, ^{
			LogVerbose(@"dispatch_release(connectTimer)");
			dispatch_release(theConnectTimer);
		});
		
        // A somewhat abstract representation of time; where zero means "now" and DISPATCH_TIME_FOREVER means "infinity" and every value in between is an opaque encoding.
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (timeout * NSEC_PER_SEC));
        
        // Sets a start time, interval, and leeway value for the connectTimer
		dispatch_source_set_timer(connectTimer, tt, DISPATCH_TIME_FOREVER, 0);
		
		dispatch_resume(connectTimer); // resumes the connection timer
	}
}


/*
    End the connection timeout
*/
- (void)endConnectTimeout
{
	LogTrace();
	
    // If there is a connection timer
	if (connectTimer)
	{
        // cancel the connect timer and set to NULL
		dispatch_source_cancel(connectTimer);
		connectTimer = NULL;
	}
	
	// Increment connectIndex.
	// This will prevent us from processing results from any related background asynchronous operations.
	// 
	// Note: This should be called from close method even if connectTimer is NULL.
	// This is because one might disconnect a socket prior to a successful connection which had no timeout.
	
	connectIndex++;
	
    // If IP version 4 connection interface
	if (connectInterface4)
	{
        // Decrease the reference count and set to nil
		[connectInterface4 release];
		connectInterface4 = nil;
	}
    
    // If IP version 6 connection interface
	if (connectInterface6)
	{
        // Decrease the reference count and set to nil
		[connectInterface6 release];
		connectInterface6 = nil;
	}
}


/*
    End the connection timeout and close the connection
*/
- (void)doConnectTimeout
{
	LogTrace();
	
	[self endConnectTimeout];
	[self closeWithError:[self connectTimeoutError]];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Disconnecting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


/*
    Close the socket with an error
    param NSError
*/
- (void)closeWithError:(NSError *)error
{
	LogTrace();
	
    // Test whether the current queue is the socketQueue
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Must be dispatched on socketQueue");
	
	
	[self endConnectTimeout];
	
    // if the current read buffer is not nil
	if (currentRead != nil)  [self endCurrentRead];
    
    // if current write buffer is not nil
	if (currentWrite != nil) 
    {
        // Cancel the timer and release the current writer
        [self endCurrentWrite];
    }
    
    // Remove all objects from the read and write queue
	[readQueue removeAllObjects];
	[writeQueue removeAllObjects];
	
    // Clear the partial read buffer
	[partialReadBuffer setLength:0];
	
    
	#if TARGET_OS_IPHONE
    
        // If there is a read or write stream
		if (readStream || writeStream)
		{
            // If set, rw streams have been added to handshake listener thread
			if (flags & kAddedHandshakeListener)
			{
                
				[[self class] performSelector:@selector(removeHandshakeListener:)
				                     onThread:sslHandshakeThread
				                   withObject:self
			                waitUntilDone:YES];
			}
			
            // if there is a read stream
			if (readStream)
			{
                
				CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);
                
                // Close and release the read stream
				CFReadStreamClose(readStream);
				CFRelease(readStream);
				readStream = NULL;
			}
            
            // if there is a write stream
			if (writeStream)
			{
				CFWriteStreamSetClient(writeStream, kCFStreamEventNone, NULL, NULL);
                
                // Close and release the write stream
				CFWriteStreamClose(writeStream);
				CFRelease(writeStream);
				writeStream = NULL;
			}
		}
	#else // if not an IPHONE Operating System
    
        // Set the ssl readbuffer to zero length
		[sslReadBuffer setLength:0];
    
		if (sslContext)
		{
			SSLDisposeContext(sslContext);
			sslContext = NULL;
		}
	#endif
	
	// For some crazy reason (in my opinion), cancelling a dispatch source doesn't
	// invoke the cancel handler if the dispatch source is paused.
	// So we have to unpause the source if needed.
	// This allows the cancel handler to be run, which in turn releases the source and closes the socket.
	
    // If there is an accept source for IP version 4
	if (accept4Source)
	{
		LogVerbose(@"dispatch_source_cancel(accept4Source)");
		dispatch_source_cancel(accept4Source);
		
		// We never suspend accept4Source
		
		accept4Source = NULL;
	}
	
    // If there is an accept source for IP version 6
	if (accept6Source)
	{
		LogVerbose(@"dispatch_source_cancel(accept6Source)");
		dispatch_source_cancel(accept6Source);
		
		// We never suspend accept6Source
		
		accept6Source = NULL;
	}
	
    // if there is a readSource
	if (readSource)
	{
		LogVerbose(@"dispatch_source_cancel(readSource)");
        
        //  Asynchronously cancel the dispatch source, preventing any further invocation of its event handler block.
		dispatch_source_cancel(readSource);
		
		[self resumeReadSource];
		
		readSource = NULL;
	}
	
    // If there is a writeSource which automatically submit event handler blocks to dispatch queues in response to external events
	if (writeSource)
	{
		LogVerbose(@"dispatch_source_cancel(writeSource)");
        
        // Asynchronously cancel the writeSource, preventing any further invocation of its event handler block.
		dispatch_source_cancel(writeSource);
		
        
		[self resumeWriteSource];
		
		writeSource = NULL;
	}
	
	// The sockets will be closed by the cancel handlers of the corresponding source
	
	socket4FD = SOCKET_NULL;
	socket6FD = SOCKET_NULL;
	
	// If the client has passed the connect/accept method, then the connection has at least begun.
	// Notify delegate that it is now ending.
	BOOL shouldCallDelegate = (flags & kSocketStarted);
	
	// Clear stored socket info and all flags (config remains as is)
	socketFDBytesAvailable = 0;
	flags = 0;
	
	if (shouldCallDelegate)
	{
		if (delegateQueue && [delegate respondsToSelector: @selector(socketDidDisconnect:withError:)])
		{
			id theDelegate = delegate;
			
            // Submits a block for asynchronous execution on the delegateQueue
			dispatch_async(delegateQueue, ^{
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
				[theDelegate socketDidDisconnect:self withError:error];
				
				[pool drain];
			});  // END OF BLOCK
		}	
	}
}


/*
    This message immediately disconnects the receiver.
    Disconnects immediately. Any pending reads or writes are dropped.
    This method is synchronous. If the socket is not already disconnected, the socketDidDisconnect:withError: delegate method will be called immediately, before this method returns.
*/
- (void)disconnect
{
    // The prototype of blocks submitted to dispatch queues, which take no arguments and have no return value.
	dispatch_block_t block = ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
        
        // If set, socket has been started (accepting/connecting)
		if (flags & kSocketStarted)
		{
			[self closeWithError:nil];
		}
		
		[pool drain];
	}; // END OF BLOCK
	
	// Synchronous disconnection, as documented in the header file
	
	if (dispatch_get_current_queue() == socketQueue)
		block();
	else
		dispatch_sync(socketQueue, block);
}


/*
    This message will disconnect the receiver after all pending read operations are completed. Pending write operations will not prevent the receiver from disconnecting.
*/
- (void)disconnectAfterReading
{
    // Submits a block for asynchronous execution on the socketQueue
	dispatch_async(socketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
        // If set, socket has been started (accepting/connecting)
		if (flags & kSocketStarted)
		{
            
            // If set, no new reads or writes are allowed
            // If set, disconnect after no more reads are queued
			flags |= (kForbidReadsWrites | kDisconnectAfterReads);
			[self maybeClose];
		}
		
		[pool drain];
	}); // END OF BLOCK
}


/*
    Disconnects the socket after writing the data
    Disconnects after all pending writes have completed. This method is asynchronous and returns immediately (even if there are no pending writes).
    After calling this method, the read and write methods will do nothing. The socket will disconnect even if there are still pending reads.

*/
- (void)disconnectAfterWriting
{
    // Submits a block for asynchronous execution on the socketQueue
	dispatch_async(socketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		if (flags & kSocketStarted)
		{
			flags |= (kForbidReadsWrites | kDisconnectAfterWrites);
			[self maybeClose];
		}
		
		[pool drain];
	}); // END OF BLOCK
}


/*
    Disconnect the socket after reading and writing
 
    Disconnects after all pending reads and writes have completed. This method is asynchronous and returns immediately (even if there are no pending reads or writes).
    After calling this, the read and write methods will do nothing.
*/
- (void)disconnectAfterReadingAndWriting
{
    
    // Submits a block for asynchronous execution on the socketQueue
	dispatch_async(socketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
        // If set, socket has been started (accepting/connecting)
		if (flags & kSocketStarted)
		{
			flags |= (kForbidReadsWrites | kDisconnectAfterReads | kDisconnectAfterWrites);
			[self maybeClose];
		}
		
		[pool drain];
	}); // END OF BLOCK
}

/**
    Closes the socket if possible.
    That is, if all writes have completed, and we're set to disconnect after writing, or if all reads have completed, and we're set to disconnect after reading.
**/
- (void)maybeClose
{
    // Test whether the current queue is the socketQueue
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Must be dispatched on socketQueue");
	
    
    // Set the flag for whether we should close the connection until after we have checked the read and write queues, and check whether we are currently reading or writing to the socket
	BOOL shouldClose = NO;
	
    // If set, disconnect after no more reads are queued
	if (flags & kDisconnectAfterReads)
	{
        // If there is anything in the readQueue and not currently reading from the socket
		if (([readQueue count] == 0) && (currentRead == nil))
		{
            // If the flag is set to disconnect the socket after writing
			if (flags & kDisconnectAfterWrites)
			{
                // Check if there is anything in the writeQueue and whether currently writing to the socket
				if (([writeQueue count] == 0) && (currentWrite == nil))
				{
					shouldClose = YES;
				}
			}
			else
			{
				shouldClose = YES;
			}
		}
	}
    // If set, disconnect after no more writes are queued
	else if (flags & kDisconnectAfterWrites)
	{
        // Check if there is anything in the writeQueue and whether currently writing to the socket
		if (([writeQueue count] == 0) && (currentWrite == nil))
		{
            // Set the flag to close the socket
			shouldClose = YES;
		}
	}
	
	if (shouldClose)
	{
        // Close without an error
		[self closeWithError:nil];
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Errors
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


/*
    Returns bad configuration error
    param NSString
    returns NSError
*/
- (NSError *)badConfigError:(NSString *)errMsg
{
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketBadConfigError userInfo:userInfo];
}


/*
    Returns bad parameter error
    param NSString
    returns NSError
*/
- (NSError *)badParamError:(NSString *)errMsg
{
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketBadParamError userInfo:userInfo];
}

/*
    param int
    returns NSError
*/
- (NSError *)gaiError:(int)gai_error
{
	NSString *errMsg = [NSString stringWithCString:gai_strerror(gai_error) encoding:NSASCIIStringEncoding];
    
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:@"kCFStreamErrorDomainNetDB" code:gai_error userInfo:userInfo];
}

/*
    Returns an error message based on the error number
    param NSString
    returns NSError
*/
- (NSError *)errnoErrorWithReason:(NSString *)reason
{
	NSString *errMsg = [NSString stringWithUTF8String:strerror(errno)];
    
    // Wraps the error message in an NSDictionary object
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:errMsg, NSLocalizedDescriptionKey,
            reason, NSLocalizedFailureReasonErrorKey, nil];
	
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:userInfo];
}

/*
    Returns an error message based on the error number
    returns NSError
*/
- (NSError *)errnoError
{
	NSString *errMsg = [NSString stringWithUTF8String:strerror(errno)];
    
    // Wraps the error message in an NSDictionary object
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:userInfo];
}

/*
    Returns an SSL error message
    param OSStatus
    returns NSError
*/
- (NSError *)sslError:(OSStatus)ssl_error
{
    
	NSString *msg = @"Error code definition can be found in Apple's SecureTransport.h";
    
    // Wraps the error message in an NSDictionary object
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:msg forKey:NSLocalizedRecoverySuggestionErrorKey];
	
	return [NSError errorWithDomain:@"kCFStreamErrorDomainSSL" code:ssl_error userInfo:userInfo];
}


/*
    Returns a connection timeout error message
    returns NSError
*/
- (NSError *)connectTimeoutError
{
    // Creates a localized erro message
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketConnectTimeoutError",
            @"GCDAsyncSocket", [NSBundle mainBundle],
            @"Attempt to connect to host timed out", nil);
	
    // Wraps the error message in an NSDictionary object
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketConnectTimeoutError userInfo:userInfo];
}

/**
    Returns a standard AsyncSocket maxed out error.
    returns NSError
**/
- (NSError *)readMaxedOutError
{
    // Creates a localized error message
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketReadMaxedOutError",
            @"GCDAsyncSocket", [NSBundle mainBundle],
            @"Read operation reached set maximum length", nil);
	
    // Wraps the error message in an NSDictionary object
	NSDictionary *info = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketReadMaxedOutError userInfo:info];
}

/**
    Returns a standard AsyncSocket write timeout error.
    returns NSError
**/
- (NSError *)readTimeoutError
{
    // Creates a localized error message
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketReadTimeoutError",
            @"GCDAsyncSocket", [NSBundle mainBundle],
            @"Read operation timed out", nil);
	
    // Wraps the error message in an NSDictionary object
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketReadTimeoutError userInfo:userInfo];
}

/**
    Returns a standard AsyncSocket write timeout error.
    returns NSError
**/
- (NSError *)writeTimeoutError
{
    // Creates a localized error message
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketWriteTimeoutError",
                @"GCDAsyncSocket", [NSBundle mainBundle],
                @"Write operation timed out", nil);
	
    // Wraps the error message in an NSDictionary object
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
    
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketWriteTimeoutError userInfo:userInfo];
}


/*
    returns NSError
*/
- (NSError *)connectionClosedError
{
	NSString *errMsg = NSLocalizedStringWithDefaultValue(@"GCDAsyncSocketClosedError",
                @"GCDAsyncSocket", [NSBundle mainBundle],
                @"Socket closed by remote peer", nil);
	
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketClosedError userInfo:userInfo];
}


/*
    param NSString
    returns NSError
*/
- (NSError *)otherError:(NSString *)errMsg
{
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	
	return [NSError errorWithDomain:GCDAsyncSocketErrorDomain code:GCDAsyncSocketOtherError userInfo:userInfo];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Diagnostics
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/*
    returns BOOL
*/
- (BOOL)isDisconnected
{
    
    // Gets result from the block
	__block BOOL result;
	
    
    // Whether socket has been started (accepting/connecting)
	dispatch_block_t block = ^{
		result = (flags & kSocketStarted) ? NO : YES;
	};
	
    
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
		block();
	else
		dispatch_sync(socketQueue, block);
	
	return result;
}


/*
    This message may be sent to determine whether the receiver is connected and capable of reading and writing.
    returns BOOL
*/
- (BOOL)isConnected
{
    // Gets the result from the block
	__block BOOL result;
	
    // The prototype of blocks submitted to dispatch queues, which take no arguments and have no return value.
	dispatch_block_t block = ^{
		result = (flags & kConnected) ? YES : NO;
	}; // END OF BLOCK
	
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_sync(socketQueue, block);
	}
    
	return result;
}

/*
    This message returns the IP address of the connected remote socket as a string.
 
    If the socket is not connected, returns nil.

    returns NSString
*/
- (NSString *)connectedHost
{
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
	{
		if (socket4FD != SOCKET_NULL)
			return [self connectedHostFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self connectedHostFromSocket6:socket6FD];
		
		return nil;
	}
	else
	{
        // Gets the result from the block
		__block NSString *result = nil;
		
		dispatch_sync(socketQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			
			if (socket4FD != SOCKET_NULL)
            {
				result = [[self connectedHostFromSocket4:socket4FD] retain];
			}else if (socket6FD != SOCKET_NULL){
				result = [[self connectedHostFromSocket6:socket6FD] retain];
			}
            
			[pool drain];
		});
		
		return [result autorelease];
	}
}


/*
    This message returns the port number of the connected remote socket.

    returns UInt16
*/
- (UInt16)connectedPort
{
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
	{
		if (socket4FD != SOCKET_NULL)
        {
			return [self connectedPortFromSocket4:socket4FD];
        }
        
		if (socket6FD != SOCKET_NULL)
        {
			return [self connectedPortFromSocket6:socket6FD];
		}
        
		return 0;
	}
	else
	{
        // Gets the result from the block
		__block UInt16 result = 0;
		
        // Submits a block for synchronous execution on the socketQueue
		dispatch_sync(socketQueue, ^{
			// No need for autorelease pool
			
			if (socket4FD != SOCKET_NULL)
				result = [self connectedPortFromSocket4:socket4FD];
			else if (socket6FD != SOCKET_NULL)
				result = [self connectedPortFromSocket6:socket6FD];
		}); // END OF BLOCK
		
		return result;
	}
}

/*
    This method returns the local IP address of the receiver as a string.
    returns NSString
*/
- (NSString *)localHost
{
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
	{
		if (socket4FD != SOCKET_NULL)
        {
			return [self localHostFromSocket4:socket4FD];
        }
        
		if (socket6FD != SOCKET_NULL)
        {
			return [self localHostFromSocket6:socket6FD];
		}
        
		return nil;
	}
	else
	{
        // Gets the result from the block
		__block NSString *result = nil;
		
        // Submits a block for synchronous execution on the socketQueue
		dispatch_sync(socketQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			
			if (socket4FD != SOCKET_NULL)
				result = [[self localHostFromSocket4:socket4FD] retain];
			else if (socket6FD != SOCKET_NULL)
				result = [[self localHostFromSocket6:socket6FD] retain];
			
			[pool drain];
		}); // END OF BLOCK
		
		return [result autorelease];
	}
}

/*
    This method returns the port number of the receiver.
    returns UInt16
*/
- (UInt16)localPort
{
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
	{
		if (socket4FD != SOCKET_NULL)
			return [self localPortFromSocket4:socket4FD];
		if (socket6FD != SOCKET_NULL)
			return [self localPortFromSocket6:socket6FD];
		
		return 0;
	}
	else
	{
        // Gets the result from the block
		__block UInt16 result = 0;
		
        // Submits a block for synchronous execution on the socketQueue
		dispatch_sync(socketQueue, ^{
			// No need for autorelease pool
			
			if (socket4FD != SOCKET_NULL)
				result = [self localPortFromSocket4:socket4FD];
			else if (socket6FD != SOCKET_NULL)
				result = [self localPortFromSocket6:socket6FD];
		});  // END OF BLOCK
		
		return result;
	}
}

/*
    returns NSString
*/
- (NSString *)connectedHost4
{
	if (socket4FD != SOCKET_NULL)
    {
		return [self connectedHostFromSocket4:socket4FD];
	}
    
	return nil;
}

/*
    returns NSString
*/
- (NSString *)connectedHost6
{
	if (socket6FD != SOCKET_NULL)
    {
		return [self connectedHostFromSocket6:socket6FD];
	}
    
	return nil;
}

/*
    returns UInt16
*/
- (UInt16)connectedPort4
{
	if (socket4FD != SOCKET_NULL)
    {
		return [self connectedPortFromSocket4:socket4FD];
	}
    
	return 0;
}

/*
    returns UInt16
*/
- (UInt16)connectedPort6
{
	if (socket6FD != SOCKET_NULL)
    {
		return [self connectedPortFromSocket6:socket6FD];
	}
    
	return 0;
}

/*
    returns NSString
*/
- (NSString *)localHost4
{
	if (socket4FD != SOCKET_NULL)
    {
		return [self localHostFromSocket4:socket4FD];
	}
    
	return nil;
}

/*
    returns NSString
*/
- (NSString *)localHost6
{
	if (socket6FD != SOCKET_NULL)
    {
		return [self localHostFromSocket6:socket6FD];
	}
    
	return nil;
}

/*
    returns UInt16
*/
- (UInt16)localPort4
{
	if (socket4FD != SOCKET_NULL)
    {
		return [self localPortFromSocket4:socket4FD];
	}
    
	return 0;
}

/*
    returns UInt16
*/
- (UInt16)localPort6
{
	if (socket6FD != SOCKET_NULL)
    {
		return [self localPortFromSocket6:socket6FD];
	}
    
	return 0;
}

/*
    param int
    returns NSString
*/
- (NSString *)connectedHostFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromAddress4:&sockaddr4];
}

/*
    param int
    returns NSString
*/
- (NSString *)connectedHostFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromAddress6:&sockaddr6];
}

/*
    param int
    returns UInt16
*/
- (UInt16)connectedPortFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return 0;
	}
	return [[self class] portFromAddress4:&sockaddr4];
}

/*
    param int
    returns UInt16
*/
- (UInt16)connectedPortFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getpeername(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return 0;
	}
	return [[self class] portFromAddress6:&sockaddr6];
}

/*
    param int
    returns NSString
*/
- (NSString *)localHostFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromAddress4:&sockaddr4];
}

/*
    param int
    returns NSString
*/
- (NSString *)localHostFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return nil;
	}
	return [[self class] hostFromAddress6:&sockaddr6];
}

/*
    param int
    returns UInt16
*/
- (UInt16)localPortFromSocket4:(int)socketFD
{
	struct sockaddr_in sockaddr4;
	socklen_t sockaddr4len = sizeof(sockaddr4);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr4, &sockaddr4len) < 0)
	{
		return 0;
	}
	return [[self class] portFromAddress4:&sockaddr4];
}

/*
    param int
    returns UInt16
*/
- (UInt16)localPortFromSocket6:(int)socketFD
{
	struct sockaddr_in6 sockaddr6;
	socklen_t sockaddr6len = sizeof(sockaddr6);
	
	if (getsockname(socketFD, (struct sockaddr *)&sockaddr6, &sockaddr6len) < 0)
	{
		return 0;
	}
	return [[self class] portFromAddress6:&sockaddr6];
}

/*
    returns NSData
*/
- (NSData *)connectedAddress
{
    // Gets the result from the block
	__block NSData *result = nil;
	
    // The prototype of blocks submitted to dispatch queues, which take no arguments and have no return value.
	dispatch_block_t block = ^{
		if (socket4FD != SOCKET_NULL)
		{
			struct sockaddr_in sockaddr4;
			socklen_t sockaddr4len = sizeof(sockaddr4);
			
			if (getpeername(socket4FD, (struct sockaddr *)&sockaddr4, &sockaddr4len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr4 length:sockaddr4len];
			}
		}
		
		if (socket6FD != SOCKET_NULL)
		{
			struct sockaddr_in6 sockaddr6;
			socklen_t sockaddr6len = sizeof(sockaddr6);
			
			if (getpeername(socket6FD, (struct sockaddr *)&sockaddr6, &sockaddr6len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr6 length:sockaddr6len];
			}
		}
	}; // END OF BLOCK
	
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_sync(socketQueue, block);
	}
    
	return [result autorelease];
}

/*
    returns NSData
*/
- (NSData *)localAddress
{
    // Gets the result from the block
	__block NSData *result = nil;
	
    
    // The prototype of blocks submitted to dispatch queues, which take no arguments and have no return value.
	dispatch_block_t block = ^{
		if (socket4FD != SOCKET_NULL)
		{
			struct sockaddr_in sockaddr4;
			socklen_t sockaddr4len = sizeof(sockaddr4);
			
			if (getsockname(socket4FD, (struct sockaddr *)&sockaddr4, &sockaddr4len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr4 length:sockaddr4len];
			}
		}
		
		if (socket6FD != SOCKET_NULL)
		{
			struct sockaddr_in6 sockaddr6;
			socklen_t sockaddr6len = sizeof(sockaddr6);
			
			if (getsockname(socket6FD, (struct sockaddr *)&sockaddr6, &sockaddr6len) == 0)
			{
				result = [[NSData alloc] initWithBytes:&sockaddr6 length:sockaddr6len];
			}
		}
	}; // END OF BLOCK
	
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
    {
		block();
	}else{
		dispatch_sync(socketQueue, block);
	}
	return [result autorelease];
}

/*
    returns BOOL
*/
- (BOOL)isIPv4
{
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
	{
		return (socket4FD != SOCKET_NULL);
	}
	else
	{
        // Gets the result from the block
		__block BOOL result = NO;
		
        // Submits a block for synchronous execution on the socketQueue
		dispatch_sync(socketQueue, ^{
			result = (socket4FD != SOCKET_NULL);
		}); // END OF BLOCK
		
		return result;
	}
}

/*
    Whether is an IP version 6 protocol
    returns BOOL
*/
- (BOOL)isIPv6
{
    // Returns the queue on which the currently executing block is running
	if (dispatch_get_current_queue() == socketQueue)
	{
		return (socket6FD != SOCKET_NULL);
	}
	else
	{
        // Gets the result from the block
		__block BOOL result = NO;
		
        // Submits a block for synchronous execution on the socketQueue
		dispatch_sync(socketQueue, ^{
			result = (socket6FD != SOCKET_NULL);
		}); // END OF BLOCK
		
		return result;
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Finds the address of an interface description.
 * An inteface description may be an interface name (en0, en1, lo0) or corresponding IP (192.168.4.34).
 * 
 * The interface description may optionally contain a port number at the end, separated by a colon.
 * If a non-zeor port parameter is provided, any port number in the interface description is ignored.
 * 
 * The returned value is a 'struct sockaddr' wrapped in an NSData object.
 
    param NSData
    param NSData
    param NSString
    param UInt16
**/
- (void)getInterfaceAddress4:(NSData **)interfaceAddr4Ptr
                    address6:(NSData **)interfaceAddr6Ptr
             fromDescription:(NSString *)interfaceDescription
                        port:(UInt16)port
{
	NSData *addr4 = nil;
	NSData *addr6 = nil;
	
	NSString *interface = nil;
	
	NSArray *components = [interfaceDescription componentsSeparatedByString:@":"];
    
	if ([components count] > 0)
	{
		NSString *temp = [components objectAtIndex:0];
		if ([temp length] > 0)
		{
			interface = temp;
		}
	}
	if ([components count] > 1 && port == 0)
	{
		long portL = strtol([[components objectAtIndex:1] UTF8String], NULL, 10);
		
		if (portL > 0 && portL <= UINT16_MAX)
		{
			port = (UInt16)portL;
		}
	}
	
	if (interface == nil)
	{
		// ANY address
		
		struct sockaddr_in nativeAddr4;
		memset(&nativeAddr4, 0, sizeof(nativeAddr4));
		
		nativeAddr4.sin_len         = sizeof(nativeAddr4);
		nativeAddr4.sin_family      = AF_INET;  // Internal socket address family
		nativeAddr4.sin_port        = htons(port);
		nativeAddr4.sin_addr.s_addr = htonl(INADDR_ANY);
		
		struct sockaddr_in6 nativeAddr6;
		memset(&nativeAddr6, 0, sizeof(nativeAddr6));
		
		nativeAddr6.sin6_len       = sizeof(nativeAddr6);
		nativeAddr6.sin6_family    = AF_INET6; // Internal socket address family
		nativeAddr6.sin6_port      = htons(port);
		nativeAddr6.sin6_addr      = in6addr_any;
		
		addr4 = [NSData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
		addr6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
	}
	else if ([interface isEqualToString:@"localhost"] || [interface isEqualToString:@"loopback"])
	{
		// LOOPBACK address
		
		struct sockaddr_in nativeAddr4;
		memset(&nativeAddr4, 0, sizeof(nativeAddr4));
		
		nativeAddr4.sin_len         = sizeof(struct sockaddr_in);
		nativeAddr4.sin_family      = AF_INET; // internal socket address family
		nativeAddr4.sin_port        = htons(port);
		nativeAddr4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		
		struct sockaddr_in6 nativeAddr6;
		memset(&nativeAddr6, 0, sizeof(nativeAddr6));
		
		nativeAddr6.sin6_len       = sizeof(struct sockaddr_in6);
		nativeAddr6.sin6_family    = AF_INET6;// internal socket address family
		nativeAddr6.sin6_port      = htons(port);
		nativeAddr6.sin6_addr      = in6addr_loopback;
		
		addr4 = [NSData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
		addr6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
	}
	else
	{
        // Create a constant read only local attribute
		const char *iface = [interface UTF8String];
		
		struct ifaddrs *addrs;
        
        // Create a constant read only local attribute
		const struct ifaddrs *cursor;
		
		if ((getifaddrs(&addrs) == 0))
		{
			cursor = addrs;
			while (cursor != NULL)
			{
                // check if internal socket address family
				if ((addr4 == nil) && (cursor->ifa_addr->sa_family == AF_INET)) 
				{
					// IPv4
					
					struct sockaddr_in *addr = (struct sockaddr_in *)cursor->ifa_addr;
					
					if (strcmp(cursor->ifa_name, iface) == 0)
					{
						// Name match
						
						struct sockaddr_in nativeAddr4 = *addr;
						nativeAddr4.sin_port = htons(port);
						
						addr4 = [NSData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
					}
					else
					{
						char ip[INET_ADDRSTRLEN];
						
						const char *conversion;
						conversion = inet_ntop(AF_INET, &addr->sin_addr, ip, sizeof(ip));
						
						if ((conversion != NULL) && (strcmp(ip, iface) == 0))
						{
							// IP match
							
							struct sockaddr_in nativeAddr4 = *addr;
							nativeAddr4.sin_port = htons(port);
							
							addr4 = [NSData dataWithBytes:&nativeAddr4 length:sizeof(nativeAddr4)];
						}
					}
				}
				else if ((addr6 == nil) && (cursor->ifa_addr->sa_family == AF_INET6))
				{
					// IPv6
					
					struct sockaddr_in6 *addr = (struct sockaddr_in6 *)cursor->ifa_addr;
					
					if (strcmp(cursor->ifa_name, iface) == 0)
					{
						// Name match
						
						struct sockaddr_in6 nativeAddr6;
						nativeAddr6.sin6_port = htons(port);
						
						addr6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
					}
					else
					{
						char ip[INET6_ADDRSTRLEN];
						
						const char *conversion;
						conversion = inet_ntop(AF_INET6, &addr->sin6_addr, ip, sizeof(ip));
						
						if ((conversion != NULL) && (strcmp(ip, iface) == 0))
						{
							// IP match
							
							struct sockaddr_in6 nativeAddr6;
							nativeAddr6.sin6_port = htons(port);
							
							addr6 = [NSData dataWithBytes:&nativeAddr6 length:sizeof(nativeAddr6)];
						}
					}
				}
				
				cursor = cursor->ifa_next;
			}
			
			freeifaddrs(addrs);
		}
	}
	
	if (interfaceAddr4Ptr) *interfaceAddr4Ptr = addr4;
	if (interfaceAddr6Ptr) *interfaceAddr6Ptr = addr6;
}

/*
    param int
*/
- (void)setupReadAndWriteSourcesForNewlyConnectedSocket:(int)socketFD
{
	readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socketFD, 0, socketQueue);
	writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, socketFD, 0, socketQueue);
	
    /////////////////////////
	// Setup event handlers
	/////////////////////////
    
    // Sets the event handler block for the readSource
	dispatch_source_set_event_handler(readSource, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		LogVerbose(@"readEventBlock");
		
		socketFDBytesAvailable = dispatch_source_get_data(readSource);
		LogVerbose(@"socketFDBytesAvailable: %lu", socketFDBytesAvailable);
		
		if (socketFDBytesAvailable > 0)
        {
			[self doReadData];
		}else{
			[self doReadEOF];
		}
        
		[pool drain];
	}); // END OF BLOCK
	
    
    // Sets the event handler block for the writeSource
	dispatch_source_set_event_handler(writeSource, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		LogVerbose(@"writeEventBlock");
		
		flags |= kSocketCanAcceptBytes;
		[self doWriteData];
		
		[pool drain];
	});  // END OF BLOCK
	
	// Setup cancel handlers
	
    // Gets the socket file descriptor refernce count from the block
	__block int socketFDRefCount = 2;
	
	dispatch_source_t theReadSource = readSource;
	dispatch_source_t theWriteSource = writeSource;
	
    // Sets the cancellation handler block for the readSource
	dispatch_source_set_cancel_handler(readSource, ^{
		
		LogVerbose(@"readCancelBlock");
		
		LogVerbose(@"dispatch_release(readSource)");
		dispatch_release(theReadSource);
		
		if (--socketFDRefCount == 0)
		{
			LogVerbose(@"close(socketFD)");
			close(socketFD);
		}
	}); // END OF BLOCK
	
    // Sets the cancellation handler block for the writeSource
	dispatch_source_set_cancel_handler(writeSource, ^{
		
		LogVerbose(@"writeCancelBlock");
		
		LogVerbose(@"dispatch_release(writeSource)");
		dispatch_release(theWriteSource);
		
		if (--socketFDRefCount == 0)
		{
			LogVerbose(@"close(socketFD)");
			close(socketFD);
		}
	}); // END OF BLOCK
	
	// We will not be able to read until data arrives.
	// But we should be able to write immediately.
	
	socketFDBytesAvailable = 0;
	flags &= ~kReadSourceSuspended;
	
	LogVerbose(@"dispatch_resume(readSource)");
	dispatch_resume(readSource); // resumes the readSource
	
	flags |= kSocketCanAcceptBytes;
	flags |= kWriteSourceSuspended;
}

/*
    Whether using CFStream
    returns BOOL
*/
- (BOOL)usingCFStream
{
	#if TARGET_OS_IPHONE
		
		if (flags & kSocketSecure)
		{
			// Due to the fact that Apple doesn't give us the full power of SecureTransport on iOS,
			// we are relegated to using the slower, less powerful, and RunLoop based CFStream API. :( Boo!
			// 
			// Thus we're not able to use the GCD read/write sources in this particular scenario.
			
			return YES;
		}
		
	#endif
	
	return NO;
}

/*
    Suspends the readSource
*/
- (void)suspendReadSource
{
	if (!(flags & kReadSourceSuspended))
	{
		LogVerbose(@"dispatch_suspend(readSource)");
		
		dispatch_suspend(readSource); // Suspends the readSource
		flags |= kReadSourceSuspended;
	}
}

/*
    Resume the readSource
*/
- (void)resumeReadSource
{
	if (flags & kReadSourceSuspended)
	{
		LogVerbose(@"dispatch_resume(readSource)");
		
		dispatch_resume(readSource); // resumes the readSource
		flags &= ~kReadSourceSuspended;
	}
}

/*
    Suspends the writeSource
*/
- (void)suspendWriteSource
{
	if (!(flags & kWriteSourceSuspended))
	{
		LogVerbose(@"dispatch_suspend(writeSource)");
		
		dispatch_suspend(writeSource); // Suspends the writeSource
		flags |= kWriteSourceSuspended;
	}
}

/*
    Resume the writeSource
*/
- (void)resumeWriteSource
{
	if (flags & kWriteSourceSuspended)
	{
		LogVerbose(@"dispatch_resume(writeSource)");
		
        // Resumes the invocation of blocks on the writeSource
		dispatch_resume(writeSource);
        
        // If set, the write source is suspended
		flags &= ~kWriteSourceSuspended;
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Reading
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/*
    Reads the data as it arrives
    param NSTimeInterval
    param int
*/
- (void)readDataWithTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataWithTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}

/*
    Reads the data as it arrives
    param NSTimeInterval
    param NSMutableData
    param NSUInteger
    param long
*/
- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                        tag:(long)tag
{
	[self readDataWithTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}

/*
    Reads the data as it arrives
    param NSTimeInterval
    param NSMutableData
    param NSUInteger
    param NSUInteger
    param long
*/
- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                  maxLength:(NSUInteger)length
                        tag:(long)tag
{
	if (offset > [buffer length]) return;
	
    
    
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
            startOffset:offset
            maxLength:length
            timeout:timeout
            readLength:0
            terminator:nil
            tag:tag];
	
    // Submits a block for asynchronous execution on the socketQueue
	dispatch_async(socketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		LogTrace();
		
        // If set, socket has been started (accepting/connecting)
        // If set, no new reads or writes are allowed
		if ((flags & kSocketStarted) && !(flags & kForbidReadsWrites))
		{
            // Add a packet to the readQueue
			[readQueue addObject:packet];
            
            // This method starts a new read, if needed.
			[self maybeDequeueRead];
		}
		
		[pool drain];
	}); // END OF BLOCK
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
	[packet release];
}

/*
    Reads a certain number of bytes from the remote socket
    Can only be used when you know the size of the data stream and want the entire stream returned in a single data object:
    param NSUInteger
    param NSTimeInterval
    param long
*/
- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataToLength:length withTimeout:timeout buffer:nil bufferOffset:0 tag:tag];
}

/*
    Reads a certain number of bytes from the remote socket
    Can only be used when you know the size of the data stream and want the entire stream returned in a single data object:

    param NSUInteger
    param NSTimeInterval
    param NSMutableData
    param NSUInteger
    param long
*/
- (void)readDataToLength:(NSUInteger)length //Number of bytes that the receiver should read.
             withTimeout:(NSTimeInterval)timeout //The number of seconds from the start of the read operation in which the operation must complete
                  buffer:(NSMutableData *)buffer
            bufferOffset:(NSUInteger)offset
                     tag:(long)tag // An application-defined integer or pointer that will be sent as an argument to the -socket:didReadData:withTag: message sent to the delegate.
{
	if (length == 0) return;
	if (offset > [buffer length]) return;
	
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
                startOffset:offset
                maxLength:0
                timeout:timeout
                readLength:length
                terminator:nil
                tag:tag];
	
    
    //Submits a block for asynchronous execution on the socketQueue
	dispatch_async(socketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		LogTrace();
		
		if ((flags & kSocketStarted) && !(flags & kForbidReadsWrites))
		{
            // Adds packet to readQueue
			[readQueue addObject:packet];
			[self maybeDequeueRead];
		}
		
		[pool drain];
	}); // END OF BLOCK
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
	[packet release];
}

/*
    Reads all bytes up to (and including) a delimiter sequence
    data - A sequence of bytes that mark the end of the read operation
    timeout - The number of seconds from the start of the read operation in which the operation must complete
    tag - An application-defined integer or pointer that will be sent as an argument to the -socket:didReadData:withTag: message sent to the delegate.
    param NSData
    param NSTimeInterval
    param long
 
*/
- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}

/*
    Reads all bytes up to (and including) a delimiter sequence
    param NSData
    param NSTimeInterval
    param NSMutableData
    param NSUInteger
    param long
*/
- (void)readDataToData:(NSData *)data
           withTimeout:(NSTimeInterval)timeout
                buffer:(NSMutableData *)buffer
          bufferOffset:(NSUInteger)offset
                   tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}


/*
    Reads all bytes up to (and including) a delimiter sequence
    param NSData
    param NSTimeInterval
    param NSUInteger
    param long
*/
- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout maxLength:(NSUInteger)length tag:(long)tag
{
	[self readDataToData:data withTimeout:timeout buffer:nil bufferOffset:0 maxLength:length tag:tag];
}

/*
    Reads all bytes up to (and including) a delimiter sequence
    param NSData
    param NSTimeInterval
    param NSMutableData
    param NSUInteger
    param NSUInteger
    param long
*/
- (void)readDataToData:(NSData *)data
           withTimeout:(NSTimeInterval)timeout
                buffer:(NSMutableData *)buffer
          bufferOffset:(NSUInteger)offset
             maxLength:(NSUInteger)length
                   tag:(long)tag
{
	if (data == nil || [data length] == 0) return;
	if (offset > [buffer length]) return;
	if (length > 0 && length < [data length]) return;
	
	GCDAsyncReadPacket *packet = [[GCDAsyncReadPacket alloc] initWithData:buffer
                startOffset:offset
                maxLength:length
                timeout:timeout
                readLength:0
                terminator:data
                tag:tag];
	
    
    // Submits a block for asynchronous execution on a socketQueue.
	dispatch_async(socketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		LogTrace();
		
		if ((flags & kSocketStarted) && !(flags & kForbidReadsWrites))
		{
            // Adds packet to the readQueue
			[readQueue addObject:packet];
			[self maybeDequeueRead];
		}
		
		[pool drain];
	}); // END OF BLOCK
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
	[packet release];
}

/**
 * This method starts a new read, if needed.
 * 
 * It is called when:
 * - a user requests a read
 * - after a read request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
**/
- (void)maybeDequeueRead
{
	LogTrace();
    
    // Test whether the current queue is socketQueue
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Must be dispatched on socketQueue");
	
	// If we're not currently processing a read AND we have an available read stream
	if ((currentRead == nil) && (flags & kConnected))
	{
        // If there a packet in the readQueue
		if ([readQueue count] > 0)
		{
			// Dequeue the next object in the write queue
			currentRead = [[readQueue objectAtIndex:0] retain];
			[readQueue removeObjectAtIndex:0];
			
			// Check if the packet from the readQueue is a special packet
			if ([currentRead isKindOfClass:[GCDAsyncSpecialPacket class]])
			{
				LogVerbose(@"Dequeued GCDAsyncSpecialPacket");
				
				// Attempt to start TLS
				flags |= kStartingReadTLS;
				
				// This method won't do anything unless both kStartingReadTLS and kStartingWriteTLS are set
				[self maybeStartTLS];
			}
			else // if the packet from the readQueue is not a special packet
			{
				LogVerbose(@"Dequeued GCDAsyncReadPacket");
				
				// Setup read timer (if needed)
				[self setupReadTimerWithTimeout:currentRead->timeout];
				
				// Immediately read, if possible
				[self doReadData];
			}
		}
        
        // If disconnecting the socket after reading
		else if (flags & kDisconnectAfterReads)
		{
            // If disconnecting the socket after writing
			if (flags & kDisconnectAfterWrites)
			{
                // Check if there is anything in the writeQueue to write to the socket, and am not currently writing anything to the socket
				if (([writeQueue count] == 0) && (currentWrite == nil))
				{
                    
					[self closeWithError:nil];
				}
			}
			else
			{
				[self closeWithError:nil];
			}
		}
	}
}


/*
 
*/
- (void)doReadData
{
	LogTrace();
	
	// This method is called on the socketQueue.
	// It might be called directly, or via the readSource when data is available to be read.

	// If not currently reading, and reads are not paused due to a possible timeout
	if ((currentRead == nil) || (flags & kReadsPaused))
	{
		LogVerbose(@"No currentRead or kReadsPaused");
		
		// Unable to read at this time
		
        // If using CFStream
		if ([self usingCFStream])
		{
			// CFReadStream only fires once when there is available data.
			// It won't fire again until we've invoked CFReadStreamRead.
		}
		else // If not using the CFStream
		{
			// If the readSource is firing, we need to pause it
			// or else it will continue to fire over and over again.
			// 
			// If the readSource is not firing,
			// we want it to continue monitoring the socket.
			
			if (socketFDBytesAvailable > 0)
			{
				[self suspendReadSource];
			}
		}
		return;
	}
	
	BOOL hasBytesAvailable;
	unsigned long estimatedBytesAvailable;
	
	#if TARGET_OS_IPHONE
    
        // If set, socket is using secure communication via SSL/TLS
		if (flags & kSocketSecure)
		{
			// Relegated to using CFStream... :( Boo! Give us SecureTransport Apple!
			
			estimatedBytesAvailable = 0;
			hasBytesAvailable = (flags & kSecureSocketHasBytesAvailable) ? YES : NO;
		}
		else // If socket is not using secure communications
		{
			estimatedBytesAvailable = socketFDBytesAvailable;
			hasBytesAvailable = (estimatedBytesAvailable > 0);
			
		}
	#else // if not IOS
		estimatedBytesAvailable = socketFDBytesAvailable + [sslReadBuffer length];
    
		hasBytesAvailable = (estimatedBytesAvailable > 0);
	#endif
	
	if ((hasBytesAvailable == NO) && ([partialReadBuffer length] == 0))
	{
		LogVerbose(@"No data available to read...");
		
		// No data available to read.
		
		if (![self usingCFStream])
		{
			// Need to wait for readSource to fire and notify us of
			// available data in the socket's internal read buffer.
			
			[self resumeReadSource];
		}
		return;
	}
	
    
    // If set, we're waiting for TLS negotiation to complete
	if (flags & kStartingReadTLS)
	{
		LogVerbose(@"Waiting for SSL/TLS handshake to complete");
		
		// The readQueue is waiting for SSL/TLS handshake to complete.
		if (flags & kStartingWriteTLS)
		{
			#if !TARGET_OS_IPHONE
			
				// We are in the process of a SSL Handshake.
				// We were waiting for incoming data which has just arrived.
				
				[self continueSSLHandshake];
			
			#endif
		}
		else // if the readQueue is not waiting for SSL/TLS handshake to complete
		{
			// We are still waiting for the writeQueue to drain and start the SSL/TLS process.
			// We now know data is available to read.
			
            // If not using CFStream
			if (![self usingCFStream])
			{
				// Suspend the read source or else it will continue to fire nonstop.
				
				[self suspendReadSource];
			}
		}
		
		return;
	}
	
	BOOL done        = NO;  // Completed read operation
	BOOL waiting     = NO;  // Ran out of data, waiting for more
	BOOL socketEOF   = NO;  // Nothing more to read (end of file)
	NSError *error   = nil; // Error occured
	
	NSUInteger totalBytesReadForCurrentRead = 0;
	
	// 
	// STEP 1 - READ FROM PREBUFFER
	// 
	
	NSUInteger partialReadBufferLength = [partialReadBuffer length];
	
    
    // If there is data in the partial read buffer
	if (partialReadBufferLength > 0)
	{
		// There are 3 types of read packets:
		// 
		// 1) Read all available data.
		// 2) Read a specific length of data.
		// 3) Read up to a particular terminator.
		
		NSUInteger bytesToCopy;
		
        
		if (currentRead->term != nil)
		{
			// Read type #3 - read up to a terminator
			
			bytesToCopy = [currentRead readLengthForTermWithPreBuffer:partialReadBuffer found:&done];
		}
		else
		{
			// Read type #1 or #2
			
			bytesToCopy = [currentRead readLengthForNonTermWithHint:partialReadBufferLength];
		}
		
		// Make sure we have enough room in the buffer for our read.
		
		[currentRead ensureCapacityForAdditionalDataOfLength:bytesToCopy];
		
		// Copy bytes from prebuffer into packet buffer
		
		void *buffer = [currentRead->buffer mutableBytes] + currentRead->startOffset + currentRead->bytesDone;
		
		memcpy(buffer, [partialReadBuffer bytes], bytesToCopy);
		
		// Remove the copied bytes from the partial read buffer
		[partialReadBuffer replaceBytesInRange:NSMakeRange(0, bytesToCopy) withBytes:NULL length:0];
		partialReadBufferLength -= bytesToCopy;
		
		LogVerbose(@"copied(%lu) partialReadBufferLength(%lu)", bytesToCopy, partialReadBufferLength);
		
		// Update totals
		
		currentRead->bytesDone += bytesToCopy;
		totalBytesReadForCurrentRead += bytesToCopy;
		
		// Check to see if the read operation is done
		
		if (currentRead->readLength > 0)
		{
			// Read type #2 - read a specific length of data
			
			done = (currentRead->bytesDone == currentRead->readLength);
		}
		else if (currentRead->term != nil)
		{
			// Read type #3 - read up to a terminator
			
			// Our 'done' variable was updated via the readLengthForTermWithPreBuffer:found: method
			
			if (!done && currentRead->maxLength > 0)
			{
				// We're not done and there's a set maxLength.
				// Have we reached that maxLength yet?
				
				if (currentRead->bytesDone >= currentRead->maxLength)
				{
					error = [self readMaxedOutError];
				}
			}
		}
		else
		{
			// Read type #1 - read all available data
			// 
			// We're done as soon as we've read all available data.
			// There might still be data in the socket to read,
			// so we're not done yet.
		}
		
	}
	
	/////////////////////////////// 
	// STEP 2 - READ FROM SOCKET
	/////////////////////////////// 
	
	if (!done && !error && hasBytesAvailable)
	{
		NSAssert((partialReadBufferLength == 0), @"Invalid logic");
		
		// There are 3 types of read packets:
		// 
		// 1) Read all available data.
		// 2) Read a specific length of data.
		// 3) Read up to a particular terminator.
		
		BOOL readIntoPartialReadBuffer = NO;
		NSUInteger bytesToRead;
		
		if ([self usingCFStream])
		{
			// Since Apple has neglected to make SecureTransport available on iOS,
			// we are relegated to using the slower, less powerful, RunLoop based CFStream API.
			// 
			// This API doesn't tell us how much data is available on the socket to be read.
			// If we had that information we could optimize our memory allocations, and sys calls.
			// 
			// But alas...
			// So we do it old school, and just read as much data from the socket as we can.
			
			NSUInteger defaultReadLength = (1024 * 32);
			
			bytesToRead = [currentRead optimalReadLengthWithDefault:defaultReadLength
			                                        shouldPreBuffer:&readIntoPartialReadBuffer];
		}
		else
		{
			if (currentRead->term != nil)
			{
				// Read type #3 - read up to a terminator
				
				bytesToRead = [currentRead readLengthForTermWithHint:estimatedBytesAvailable
													 shouldPreBuffer:&readIntoPartialReadBuffer];
			}
			else
			{
				// Read type #1 or #2
				
				bytesToRead = [currentRead readLengthForNonTermWithHint:estimatedBytesAvailable];
			}
		}
		
		if (bytesToRead > SIZE_MAX) // NSUInteger may be bigger than size_t (read param 3)
		{
			bytesToRead = SIZE_MAX;
		}
		
		// Make sure we have enough room in the buffer for our read.
		// 
		// We are either reading directly into the currentRead->buffer,
		// or we're reading into the temporary partialReadBuffer.
		
		void *buffer;
		
		if (readIntoPartialReadBuffer)
		{
			if (bytesToRead > partialReadBufferLength)
			{
				[partialReadBuffer setLength:bytesToRead];
			}
			
			buffer = [partialReadBuffer mutableBytes];
		}
		else
		{
			[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
			
			buffer = [currentRead->buffer mutableBytes] + currentRead->startOffset + currentRead->bytesDone;
		}
		
		// Read data into buffer
		
		size_t bytesRead = 0;
		
        
        // If set, socket is using secure communication via SSL/TLS
		if (flags & kSocketSecure)
		{
			#if TARGET_OS_IPHONE
				
				CFIndex result = CFReadStreamRead(readStream, (UInt8 *)buffer, (CFIndex)bytesToRead);
				LogVerbose(@"CFReadStreamRead(): result = %i", (int)result);
				
				if (result < 0)
				{
					error = [NSMakeCollectable(CFReadStreamCopyError(readStream)) autorelease];
					
					if (readIntoPartialReadBuffer)
						[partialReadBuffer setLength:0];
				}
				else if (result == 0)
				{
					socketEOF = YES;
					
					if (readIntoPartialReadBuffer)
						[partialReadBuffer setLength:0];
				}
				else
				{
					waiting = YES;
					bytesRead = (size_t)result;
				}
				
				// We only know how many decrypted bytes were read.
				// The actual number of bytes read was likely more due to the overhead of the encryption.
				// So we reset our flag, and rely on the next callback to alert us of more data.
				flags &= ~kSecureSocketHasBytesAvailable;
				
			#else
				
                // OSStatus is 4-bytes representing an error number
				OSStatus result = SSLRead(sslContext, buffer, (size_t)bytesToRead, &bytesRead);
            
				LogVerbose(@"read from secure socket = %u", (unsigned)bytesRead);
			
                // Check if there was an error doing the SSLRead
				if (result != noErr)
				{
					bytesRead = 0;
					
					if (result == errSSLWouldBlock)
                    {
						waiting = YES;
					}else{
						error = [self sslError:result];
					}
					if (readIntoPartialReadBuffer)
                    { 
						[partialReadBuffer setLength:0];
                    }
				}
				
				// Do not modify socketFDBytesAvailable.
				// It will be updated via the SSLReadFunction().
				
			#endif
		}
		else  // If not using secure communications
		{
			int socketFD = (socket4FD == SOCKET_NULL) ? socket6FD : socket4FD;
			
            
			ssize_t result = read(socketFD, buffer, (size_t)bytesToRead);
			LogVerbose(@"read from socket = %i", (int)result);
			
            
			if (result < 0)
			{
				if (errno == EWOULDBLOCK)
					waiting = YES;
				else
					error = [self errnoErrorWithReason:@"Error in read() function"];
				
				socketFDBytesAvailable = 0;
				
				if (readIntoPartialReadBuffer)
					[partialReadBuffer setLength:0];
			}
			else if (result == 0)
			{
				socketEOF = YES;
				socketFDBytesAvailable = 0;
				
				if (readIntoPartialReadBuffer)
					[partialReadBuffer setLength:0];
			}
			else
			{
				bytesRead = result;
				
				if (socketFDBytesAvailable <= bytesRead)
					socketFDBytesAvailable = 0;
				else
					socketFDBytesAvailable -= bytesRead;
				
				if (socketFDBytesAvailable == 0)
				{
					waiting = YES;
				}
			}
		}
		
		if (bytesRead > 0)
		{
			// Check to see if the read operation is done
			
			if (currentRead->readLength > 0)
			{
				// Read type #2 - read a specific length of data
				// 
				// Note: We should never be using a prebuffer when we're reading a specific length of data.
				
				NSAssert(readIntoPartialReadBuffer == NO, @"Invalid logic");
				
				currentRead->bytesDone += bytesRead;
				totalBytesReadForCurrentRead += bytesRead;
				
				done = (currentRead->bytesDone == currentRead->readLength);
			}
			else if (currentRead->term != nil)
			{
				// Read type #3 - read up to a terminator
				
				if (readIntoPartialReadBuffer)
				{
					// We just read a big chunk of data into the partialReadBuffer.
					// Search for the terminating sequence.
					// 
					// Note: We are depending upon [partialReadBuffer length] to tell us how much data is
					// available in the partialReadBuffer. So we need to be sure this matches how many bytes
					// have actually been read into said buffer.
					
					[partialReadBuffer setLength:bytesRead];
					
					bytesToRead = [currentRead readLengthForTermWithPreBuffer:partialReadBuffer found:&done];
					
					// Ensure there's room on the read packet's buffer
					
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesToRead];
					
					// Copy bytes from prebuffer into read buffer
					
					void *preBuf = [partialReadBuffer mutableBytes];
					void *readBuf = [currentRead->buffer mutableBytes] + currentRead->startOffset
                        + currentRead->bytesDone;
					
					memcpy(readBuf, preBuf, bytesToRead);
					
					// Remove the copied bytes from the prebuffer
					[partialReadBuffer replaceBytesInRange:NSMakeRange(0, bytesToRead) withBytes:NULL length:0];
					
					// Update totals
					currentRead->bytesDone += bytesToRead;
					totalBytesReadForCurrentRead += bytesToRead;
					
					// Our 'done' variable was updated via the readLengthForTermWithPreBuffer:found: method above
				}
				else
				{
					// We just read a big chunk of data directly into the packet's buffer.
					// We need to move any overflow into the prebuffer.
					
					NSInteger overflow = [currentRead searchForTermAfterPreBuffering:bytesRead];
					
					if (overflow == 0)
					{
						// Perfect match!
						// Every byte we read stays in the read buffer,
						// and the last byte we read was the last byte of the term.
						
						currentRead->bytesDone += bytesRead;
						totalBytesReadForCurrentRead += bytesRead;
						done = YES;
					}
					else if (overflow > 0)
					{
						// The term was found within the data that we read,
						// and there are extra bytes that extend past the end of the term.
						// We need to move these excess bytes out of the read packet and into the prebuffer.
						
						NSInteger underflow = bytesRead - overflow;
						
						// Copy excess data into partialReadBuffer
						void *overflowBuffer = buffer + currentRead->bytesDone + underflow;
						
						[partialReadBuffer appendBytes:overflowBuffer length:overflow];
						
						// Note: The completeCurrentRead method will trim the buffer for us.
						
						currentRead->bytesDone += underflow;
						totalBytesReadForCurrentRead += underflow;
						done = YES;
					}
					else
					{
						// The term was not found within the data that we read.
						
						currentRead->bytesDone += bytesRead;
						totalBytesReadForCurrentRead += bytesRead;
						done = NO;
					}
				}
				
				if (!done && currentRead->maxLength > 0)
				{
					// We're not done and there's a set maxLength.
					// Have we reached that maxLength yet?
					
					if (currentRead->bytesDone >= currentRead->maxLength)
					{
						error = [self readMaxedOutError];
					}
				}
			}
			else
			{
				// Read type #1 - read all available data
				
				if (readIntoPartialReadBuffer)
				{
					// We just read a chunk of data into the partialReadBuffer.
					// Copy the data into the read packet.
					// 
					// Recall that we didn't read directly into the packet's buffer to avoid
					// over-allocating memory since we had no clue how much data was available to be read.
					// 
					// Note: We are depending upon [partialReadBuffer length] to tell us how much data is
					// available in the partialReadBuffer. So we need to be sure this matches how many bytes
					// have actually been read into said buffer.
					
					[partialReadBuffer setLength:bytesRead];
					
					// Ensure there's room on the read packet's buffer
					
					[currentRead ensureCapacityForAdditionalDataOfLength:bytesRead];
					
					// Copy bytes from prebuffer into read buffer
					
					void *preBuf = [partialReadBuffer mutableBytes];
					void *readBuf = [currentRead->buffer mutableBytes] + currentRead->startOffset
                        + currentRead->bytesDone;
					
					memcpy(readBuf, preBuf, bytesRead);
					
					// Remove the copied bytes from the prebuffer
					[partialReadBuffer replaceBytesInRange:NSMakeRange(0, bytesRead) withBytes:NULL length:0];
					
					// Update totals
					currentRead->bytesDone += bytesRead;
					totalBytesReadForCurrentRead += bytesRead;
				}
				else
				{
					currentRead->bytesDone += bytesRead;
					totalBytesReadForCurrentRead += bytesRead;
				}
				
				done = YES;
			}
			
		} // if (bytesRead > 0)
		
	} // if (!done && !error && hasBytesAvailable)
	
	
	if (!done && currentRead->readLength == 0 && currentRead->term == nil)
	{
		// Read type #1 - read all available data
		// 
		// We might arrive here if we read data from the prebuffer but not from the socket.
		
		done = (totalBytesReadForCurrentRead > 0);
	}
	
	// Only one of the following can possibly be true:
	// 
	// - waiting
	// - socketEOF
	// - socketError
	// - maxoutError
	// 
	// They may all be false.
	// One of the above may be true even if done is true.
	// This might be the case if we completed read type #1 via data from the prebuffer.
	
	if (done)
	{
        // Complete current read from the buffer
		[self completeCurrentRead];
		
		if (!socketEOF && !error)
		{
            // starts a new read, if needed.
			[self maybeDequeueRead];
		}
	}
	else if (totalBytesReadForCurrentRead > 0)
	{
		// We're not done read type #2 or #3 yet, but we have read in some bytes
		
		if (delegateQueue && [delegate respondsToSelector:@selector(socket:didReadPartialDataOfLength:tag:)])
		{
			id theDelegate = delegate;
			GCDAsyncReadPacket *theRead = currentRead;
			
            // Submits a block for asynchronous execution on the delegateQueue
			dispatch_async(delegateQueue, ^{
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
				[theDelegate socket:self didReadPartialDataOfLength:totalBytesReadForCurrentRead tag:theRead->tag];
				
				[pool drain];
			}); // END OF BLOCK
		}
	}
	
	// Check for errors
	
	if (error)
	{
		[self closeWithError:error];
	} 
	else if (socketEOF) // if no error, check of end of file
	{
		[self doReadEOF];
	}
	else if (waiting)
	{
		if (![self usingCFStream])
		{
			// Monitor the socket for readability (if we're not already doing so)
			[self resumeReadSource];
		}
	}
	
	// Do not add any code here without first adding return statements in the error cases above.
}


/*
    Read until the end of the file terminator
*/
- (void)doReadEOF
{
	LogTrace();
	
	BOOL shouldDisconnect;
	NSError *error = nil;
	
    // If set, we're waiting for TLS negotiation to complete
	if ((flags & kStartingReadTLS) || (flags & kStartingWriteTLS))
	{
		// We received an EOF during or prior to startTLS.
		// The SSL/TLS handshake is now impossible, so this is an unrecoverable situation.
		
        
		shouldDisconnect = YES;
		
		#if !TARGET_OS_IPHONE
			error = [self sslError:errSSLClosedAbort];
		#endif
	} 
    
    // If set, the socket will stay open even if the read stream closes
	else if (config & kAllowHalfDuplexConnection)
	{
		// We just received an EOF (end of file) from the socket's read stream.
		// Query the socket to see if it is still writeable.
		
		int socketFD = (socket4FD == SOCKET_NULL) ? socket6FD : socket4FD;
		
		struct pollfd pfd[1];
		pfd[0].fd = socketFD;
		pfd[0].events = POLLOUT;
		pfd[0].revents = 0;
		
		poll(pfd, 1, 0);
		
        
		shouldDisconnect = (pfd[0].revents & POLLOUT) ? NO : YES;
	}
	else
	{
		shouldDisconnect = YES;
	}
	
	
	if (shouldDisconnect)
	{
		if (error == nil)
		{
			error = [self connectionClosedError];
		}
		[self closeWithError:error];
	}
	else
	{
		// Notify the delegate
		
		if (delegateQueue && [delegate respondsToSelector:@selector(socketDidCloseReadStream:)])
		{
			id theDelegate = delegate;
			
			dispatch_async(delegateQueue, ^{
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
				[theDelegate socketDidCloseReadStream:self];
				
				[pool drain];
			});
		}
		
		if (![self usingCFStream])
		{
			// Suspend the read source (if needed)
			
			[self suspendReadSource];
		}
	}
}
/*
    Complete current read from buffer
*/
- (void)completeCurrentRead
{
	LogTrace();
	
	NSAssert(currentRead, @"Trying to complete current read when there is no current read.");
	
	// Local variable for holding the results
	NSData *result;
	
    
	if (currentRead->bufferOwner)
	{
		// We created the buffer on behalf of the user.
		// Trim our buffer to be the proper size.
		[currentRead->buffer setLength:currentRead->bytesDone];
		
		result = currentRead->buffer;
	}
	else
	{
		// We did NOT create the buffer.
		// The buffer is owned by the caller.
		// Only trim the buffer if we had to increase its size.
		
		if ([currentRead->buffer length] > currentRead->originalBufferLength)
		{
			NSUInteger readSize = currentRead->startOffset + currentRead->bytesDone;
			NSUInteger origSize = currentRead->originalBufferLength;
			
			NSUInteger buffSize = MAX(readSize, origSize);
			
			[currentRead->buffer setLength:buffSize];
		}
		
		void *buffer = [currentRead->buffer mutableBytes] + currentRead->startOffset;
		
		result = [NSData dataWithBytesNoCopy:buffer length:currentRead->bytesDone freeWhenDone:NO];
	}
	
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:didReadData:withTag:)])
	{
		id theDelegate = delegate;
		GCDAsyncReadPacket *theRead = currentRead;
		
        // Submits a block for asynchronous execution on the delegateQueue
		dispatch_async(delegateQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			
			[theDelegate socket:self didReadData:result withTag:theRead->tag];
			
			[pool drain];
		}); // END OF BLOCK
	}
	
	[self endCurrentRead];
}

/*
    Stops the readtimer and releases the currentRead
*/
- (void)endCurrentRead
{
    // If there is a read timer
	if (readTimer)
	{
		dispatch_source_cancel(readTimer);
		readTimer = NULL;
	}
	
	[currentRead release];
	currentRead = nil;
}

/*
    Setup the read timer with a specific timeout
    param NSTimeInterval
*/
- (void)setupReadTimerWithTimeout:(NSTimeInterval)timeout
{
    // if read timer greater than 0.0
	if (timeout >= 0.0)
	{
		readTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
        // Sets the event handler block for the readTimer
		dispatch_source_set_event_handler(readTimer, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			[self doReadTimeout];
			[pool drain];
		}); // END OF BLOCK
		
		dispatch_source_t theReadTimer = readTimer;
        
        // Sets the cancellation handler block for the readTimer
		dispatch_source_set_cancel_handler(readTimer, ^{
			LogVerbose(@"dispatch_release(readTimer)");
			dispatch_release(theReadTimer);
		}); // END OF BLOCK
		
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (timeout * NSEC_PER_SEC));
		
		dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
        
        
		dispatch_resume(readTimer); // Resumes the readTimer
	}
}

/*
    Do a read timeout
*/
- (void)doReadTimeout
{
	// This is a little bit tricky.
	// Ideally we'd like to synchronously query the delegate about a timeout extension.
	// But if we do so synchronously we risk a possible deadlock.
	// So instead we have to do so asynchronously, and callback to ourselves from within the delegate block.
	
    
    // If set, reads are paused due to possible timeout
	flags |= kReadsPaused;
	
    
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:shouldTimeoutReadWithTag:elapsed:bytesDone:)])
	{
		id theDelegate = delegate;
		GCDAsyncReadPacket *theRead = currentRead;
		
        
        // Submits a block for asynchronous execution on the delegateQueue
		dispatch_async(delegateQueue, ^{
			NSAutoreleasePool *delegatePool = [[NSAutoreleasePool alloc] init];
			
			NSTimeInterval timeoutExtension = 0.0;
			
			timeoutExtension = [theDelegate socket:self shouldTimeoutReadWithTag:theRead->tag
                            elapsed:theRead->timeout
                            bytesDone:theRead->bytesDone];
			
            //Submits a block for asynchronous execution on the socketQueue
			dispatch_async(socketQueue, ^{
				NSAutoreleasePool *callbackPool = [[NSAutoreleasePool alloc] init];
				
				[self doReadTimeoutWithExtension:timeoutExtension];
				
				[callbackPool drain];
			}); // END OF BLOCK
			
			[delegatePool drain];
		}); // END OF BLOCK
	}
	else
	{
		[self doReadTimeoutWithExtension:0.0];
	}
}


/*
    Do a read timeout with a time interval
    param NSTimeInterval
*/
- (void)doReadTimeoutWithExtension:(NSTimeInterval)timeoutExtension
{
    
    // if current read from buffer
	if (currentRead)
	{
		if (timeoutExtension > 0.0)
		{
			currentRead->timeout += timeoutExtension;
			
			// Reschedule the timer
			dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (timeoutExtension * NSEC_PER_SEC));
			dispatch_source_set_timer(readTimer, tt, DISPATCH_TIME_FOREVER, 0);
			
			// Unpause reads, and continue
			flags &= ~kReadsPaused;
			[self doReadData];
		}
		else
		{
			LogVerbose(@"ReadTimeout");
			
			[self closeWithError:[self readTimeoutError]];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Writing
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


/*
    Starts asynchronous write operation
    param NSData
    param NSTimeInterval
    param long
*/
- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
	if (data == nil || [data length] == 0) return;
	
	GCDAsyncWritePacket *packet = [[GCDAsyncWritePacket alloc] initWithData:data timeout:timeout tag:tag];
	
    // Submits a block for asynchronous execution on the socketQueue
	dispatch_async(socketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		LogTrace();
		
		if ((flags & kSocketStarted) && !(flags & kForbidReadsWrites))
		{
			[writeQueue addObject:packet];
			[self maybeDequeueWrite];
		}
		
		[pool drain];
	}); // END OF BLOCK
	
	// Do not rely on the block being run in order to release the packet,
	// as the queue might get released without the block completing.
	[packet release];
}

/**
 * Conditionally starts a new write.
 * 
 * It is called when:
 * - a user requests a write
 * - after a write request has finished (to handle the next request)
 * - immediately after the socket opens to handle any pending requests
 * 
 * This method also handles auto-disconnect post read/write completion.
**/
- (void)maybeDequeueWrite
{
	LogTrace();
    
    // Test whether the current queue is the socketQueue
	NSAssert(dispatch_get_current_queue() == socketQueue, @"Must be dispatched on socketQueue");
	
	
	// If we're not currently processing a write AND we have an available write stream
	if ((currentWrite == nil) && (flags & kConnected))
	{
		if ([writeQueue count] > 0)
		{
			// Dequeue the next object in the write queue
			currentWrite = [[writeQueue objectAtIndex:0] retain];
			[writeQueue removeObjectAtIndex:0];
			
			
			if ([currentWrite isKindOfClass:[GCDAsyncSpecialPacket class]])
			{
				LogVerbose(@"Dequeued GCDAsyncSpecialPacket");
				
				// Attempt to start TLS
				flags |= kStartingWriteTLS;
				
				// This method won't do anything unless both kStartingReadTLS and kStartingWriteTLS are set
				[self maybeStartTLS];
			}
			else
			{
				LogVerbose(@"Dequeued GCDAsyncWritePacket");
				
				// Setup write timer (if needed)
				[self setupWriteTimerWithTimeout:currentWrite->timeout];
				
				// Immediately write, if possible
				[self doWriteData];
			}
		}
        // If disconnecting the socket after writing
		else if (flags & kDisconnectAfterWrites)
		{
            // If disconnecting the socket after reading
			if (flags & kDisconnectAfterReads)
			{
				if (([readQueue count] == 0) && (currentRead == nil))
				{
					[self closeWithError:nil];
				}
			}
			else
			{
				[self closeWithError:nil];
			}
		}
	}
}


/*
    Do write data
*/
- (void)doWriteData
{
	LogTrace();
	
	// This method is called by the writeSource via the socketQueue
	
    // if current write to buffer is nil, or
    // If set, writes are paused due to possible timeout
	if ((currentWrite == nil) || (flags & kWritesPaused))
	{
		LogVerbose(@"No currentWrite or kWritesPaused");
		
		// Unable to write at this time
		
		if ([self usingCFStream])
		{
			// CFWriteStream only fires once when there is available data.
			// It won't fire again until we've invoked CFWriteStreamWrite.
		}
		else // not using CFStream
		{
			// If the writeSource is firing, we need to pause it
			// or else it will continue to fire over and over again.
			
			if (flags & kSocketCanAcceptBytes)
			{
				[self suspendWriteSource];
			}
		}
		return;
	}
    
    
	// If set, we know socket can accept bytes. If unset, it's unknown.
	if (!(flags & kSocketCanAcceptBytes))
	{
		LogVerbose(@"No space available to write...");
		
		// No space available to write.
		
		if (![self usingCFStream])
		{
			// Need to wait for writeSource to fire and notify us of
			// available space in the socket's internal write buffer.
			
			[self resumeWriteSource];
		}
		return;
	}
	
    // If set, we're waiting for TLS negotiation to complete
	if (flags & kStartingWriteTLS)
	{
		LogVerbose(@"Waiting for SSL/TLS handshake to complete");
		
		// The writeQueue is waiting for SSL/TLS handshake to complete.
		
		if (flags & kStartingReadTLS)
		{
			#if !TARGET_OS_IPHONE
			
				// We are in the process of a SSL Handshake.
				// We were waiting for available space in the socket's internal OS buffer to continue writing.
			
				[self continueSSLHandshake];
			
			#endif
		}
		else
		{
			// We are still waiting for the readQueue to drain and start the SSL/TLS process.
			// We now know we can write to the socket.
			
			if (![self usingCFStream])
			{
				// Suspend the write source or else it will continue to fire nonstop.
				
				[self suspendWriteSource];
			}
		}
		
		return;
	}
	
	// Note: This method is not called if theCurrentWrite is an GCDAsyncSpecialPacket (startTLS packet)
	
	BOOL waiting = NO;
	NSError *error = nil;
	size_t bytesWritten = 0;
	
    
    // If set, socket is using secure communication via SSL/TLS
	if (flags & kSocketSecure)
	{
		#if TARGET_OS_IPHONE
			
        
            // bytes in the bufer plus the bytesDone
			void *buffer = (void *)[currentWrite->buffer bytes] + currentWrite->bytesDone;
			
			NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone;
			
			if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
			{
				bytesToWrite = SIZE_MAX;
			}
		
			CFIndex result = CFWriteStreamWrite(writeStream, (UInt8 *)buffer, (CFIndex)bytesToWrite);
			LogVerbose(@"CFWriteStreamWrite(%lu) = %li", bytesToWrite, result);
		
			if (result < 0)
			{
				error = [NSMakeCollectable(CFWriteStreamCopyError(writeStream)) autorelease];
			}
			else
			{
				bytesWritten = (size_t)result;
				
				// We always set waiting to true in this scenario.
				// CFStream may have altered our underlying socket to non-blocking.
				// Thus if we attempt to write without a callback, we may end up blocking our queue.
				waiting = YES;
			}
			
		#else
			
			// We're going to use the SSLWrite function.
			// 
			// OSStatus SSLWrite(SSLContextRef context, const void *data, size_t dataLength, size_t *processed)
			// 
			// Parameters:
			// context     - An SSL session context reference.
			// data        - A pointer to the buffer of data to write.
			// dataLength  - The amount, in bytes, of data to write.
			// processed   - On return, the length, in bytes, of the data actually written.
			// 
			// It sounds pretty straight-forward,
			// but there are a few caveats you should be aware of.
			// 
			// The SSLWrite method operates in a non-obvious (and rather annoying) manner.
			// According to the documentation:
			// 
			//   Because you may configure the underlying connection to operate in a non-blocking manner,
			//   a write operation might return errSSLWouldBlock, indicating that less data than requested
			//   was actually transferred. In this case, you should repeat the call to SSLWrite until some
			//   other result is returned.
			// 
			// This sounds perfect, but when our SSLWriteFunction returns errSSLWouldBlock,
			// then the SSLWrite method returns (with the proper errSSLWouldBlock return value),
			// but it sets bytesWritten to bytesToWrite !!
			// 
			// In other words, if the SSLWrite function doesn't completely write all the data we tell it to,
			// then it doesn't tell us how many bytes were actually written.
			// 
			// You might be wondering:
			// If the SSLWrite function doesn't tell us how many bytes were written,
			// then how in the world are we supposed to update our parameters (buffer & bytesToWrite)
			// for the next time we invoke SSLWrite?
			// 
			// The answer is that SSLWrite cached all the data we told it to write,
			// and it will push out that data next time we call SSLWrite.
			// If we call SSLWrite with new data, it will push out the cached data first, and then the new data.
			// If we call SSLWrite with empty data, then it will simply push out the cached data.
			// 
			// For this purpose we're going to break large writes into a series of smaller writes.
			// This allows us to report progress back to the delegate.
			
			OSStatus result;
			
        
        
			BOOL hasCachedDataToWrite = (sslWriteCachedLength > 0);
			BOOL hasNewDataToWrite = YES;
			
			if (hasCachedDataToWrite)
			{
				size_t processed = 0;
				
				result = SSLWrite(sslContext, NULL, 0, &processed);
				
                // If there was not an error doing the SSLWrite
				if (result == noErr)
				{
					bytesWritten = sslWriteCachedLength;
					sslWriteCachedLength = 0;
					
					if (currentWrite->bytesDone == [currentWrite->buffer length])
					{
						// We've written all data for the current write.
						hasNewDataToWrite = NO;
					}
				}
				else
				{
					if (result == errSSLWouldBlock)
					{
						waiting = YES;
					}
					else
					{
						error = [self sslError:result];
					}
					
					// Can't write any new data since we were unable to write the cached data.
					hasNewDataToWrite = NO;
				}
			}
			
			if (hasNewDataToWrite)
			{
				void *buffer = (void *)[currentWrite->buffer bytes] + currentWrite->bytesDone + bytesWritten;
				
				NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone - bytesWritten;
				
				if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
				{
					bytesToWrite = SIZE_MAX;
				}
				
				size_t bytesRemaining = bytesToWrite;
				
				BOOL keepLooping = YES;
				while (keepLooping)
				{
					size_t sslBytesToWrite = MIN(bytesRemaining, 32768);
					size_t sslBytesWritten = 0;
					
					result = SSLWrite(sslContext, buffer, sslBytesToWrite, &sslBytesWritten);
					
					if (result == noErr)
					{
						buffer += sslBytesWritten;
						bytesWritten += sslBytesWritten;
						bytesRemaining -= sslBytesWritten;
						
						keepLooping = (bytesRemaining > 0);
					}
					else
					{
						if (result == errSSLWouldBlock)
						{
							waiting = YES;
							sslWriteCachedLength = sslBytesToWrite;
						}
						else
						{
							error = [self sslError:result];
						}
						
						keepLooping = NO;
					}
					
				} // while (keepLooping)
				
			} // if (hasNewDataToWrite)
		
		#endif
	}
	else
	{
		int socketFD = (socket4FD == SOCKET_NULL) ? socket6FD : socket4FD;
		
		void *buffer = (void *)[currentWrite->buffer bytes] + currentWrite->bytesDone;
		
		NSUInteger bytesToWrite = [currentWrite->buffer length] - currentWrite->bytesDone;
		
		if (bytesToWrite > SIZE_MAX) // NSUInteger may be bigger than size_t (write param 3)
		{
			bytesToWrite = SIZE_MAX;
		}
		
		ssize_t result = write(socketFD, buffer, (size_t)bytesToWrite);
		LogVerbose(@"wrote to socket = %i", (int)result);
		
		// Check results
		if (result < 0)
		{
			if (errno == EWOULDBLOCK)
			{
				waiting = YES;
			}
			else
			{
				error = [self errnoErrorWithReason:@"Error in write() function"];
			}
		}
		else
		{
			bytesWritten = result;
		}
	}
	
	// We're done with our writing.
	// If we explictly ran into a situation where the socket told us there was no room in the buffer,
	// then we immediately resume listening for notifications.
	// 
	// We must do this before we dequeue another write,
	// as that may in turn invoke this method again.
	// 
	// Note that if CFStream is involved, it may have maliciously put our socket in blocking mode.
	
	if (waiting)
	{
		flags &= ~kSocketCanAcceptBytes;
		
		if (![self usingCFStream])
		{
			[self resumeWriteSource];
		}
	}
	
	// Check our results
	
	BOOL done = NO;
	
	if (bytesWritten > 0)
	{
		// Update total amount read for the current write
		currentWrite->bytesDone += bytesWritten;
		LogVerbose(@"currentWrite->bytesDone = %lu", currentWrite->bytesDone);
		
		// Is packet done?
		done = (currentWrite->bytesDone == [currentWrite->buffer length]);
	}
	
	if (done)
	{
		[self completeCurrentWrite];
		
		if (!error)
		{
			[self maybeDequeueWrite];
		}
	}
	else
	{
		// We were unable to finish writing the data,
		// so we're waiting for another callback to notify us of available space in the lower-level output buffer.
		
		if (!waiting & !error)
		{
			// This would be the case if our write was able to accept some data, but not all of it.
			
			flags &= ~kSocketCanAcceptBytes;
			
			if (![self usingCFStream])
			{
				[self resumeWriteSource];
			}
		}
		
		if (bytesWritten > 0)
		{
			// We're not done with the entire write, but we have written some bytes
			
			if (delegateQueue && [delegate respondsToSelector:@selector(socket:didWritePartialDataOfLength:tag:)])
			{
				id theDelegate = delegate;
				GCDAsyncWritePacket *theWrite = currentWrite;
				
				dispatch_async(delegateQueue, ^{
					NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
					
					[theDelegate socket:self didWritePartialDataOfLength:bytesWritten tag:theWrite->tag];
					
					[pool drain];
				});
			}
		}
	}
	
	// Check for errors
	
	if (error)
	{
		[self closeWithError:[self errnoErrorWithReason:@"Error in write() function"]];
	}
	
	// Do not add any code here without first adding a return statement in the error case above.
}


/*
    Complete the current write within the allotted time
*/
- (void)completeCurrentWrite
{
	LogTrace();
	
	NSAssert(currentWrite, @"Trying to complete current write when there is no current write.");
	
	
    //When an operation has completed within the allotted time, the socket will send a message to its delegate (either -socket:didReadData:withTag: or -socket:didWriteDataWithTag:). The delegate object should respond appropriately, sending another read or write message to the socket as necessary.
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:didWriteDataWithTag:)])
	{
		id theDelegate = delegate;
		GCDAsyncWritePacket *theWrite = currentWrite;
		
        // Submits a block for asynchronous execution on the delegateQueue
		dispatch_async(delegateQueue, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			
			[theDelegate socket:self didWriteDataWithTag:theWrite->tag];
			
			[pool drain];
		}); // END OF BLOCK
	}
	
    // Cancel the timer and release the current writer
	[self endCurrentWrite];
}

/*
    Stop the current write
*/
- (void)endCurrentWrite
{
    // Cancel the timer and set it to NULL
	if (writeTimer)
	{
		dispatch_source_cancel(writeTimer);
		writeTimer = NULL;
	}
	// Release the current writer and set to nil
	[currentWrite release];
	currentWrite = nil;
}


/*
    param NSTimeInterval
*/
- (void)setupWriteTimerWithTimeout:(NSTimeInterval)timeout
{
    // Check that the timeout parameter is a positive number
	if (timeout >= 0.0)
	{
        // Create a write timer
		writeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, socketQueue);
		
        
		dispatch_source_set_event_handler(writeTimer, ^{
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			
			[self doWriteTimeout];
			
			[pool drain];
		});
		
		dispatch_source_t theWriteTimer = writeTimer;
        
        // Sets the cancellation handler block for the writeTimer
		dispatch_source_set_cancel_handler(writeTimer, ^{
			LogVerbose(@"dispatch_release(writeTimer)");
			dispatch_release(theWriteTimer);
		}); // END OF BLOCK
		
		dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (timeout * NSEC_PER_SEC));
		
		dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
        
		dispatch_resume(writeTimer); // Resumes the writeTimer
	}
}


/*
 
*/
- (void)doWriteTimeout
{
	// This is a little bit tricky.
	// Ideally we'd like to synchronously query the delegate about a timeout extension.
	// But if we do so synchronously we risk a possible deadlock.
	// So instead we have to do so asynchronously, and callback to ourselves from within the delegate block.
	
    
    // If set, writes are paused due to possible timeout
	flags |= kWritesPaused;
	
    
    
	if (delegateQueue && [delegate respondsToSelector:@selector(socket:shouldTimeoutWriteWithTag:elapsed:bytesDone:)])
	{
		id theDelegate = delegate;
		GCDAsyncWritePacket *theWrite = currentWrite;
		
        // Submits a block for asynchronous execution on the delegateQueue
		dispatch_async(delegateQueue, ^{
			NSAutoreleasePool *delegatePool = [[NSAutoreleasePool alloc] init];
			
			NSTimeInterval timeoutExtension = 0.0;
			
			timeoutExtension = [theDelegate socket:self shouldTimeoutWriteWithTag:theWrite->tag
                                elapsed:theWrite->timeout
                                bytesDone:theWrite->bytesDone];
			
            // Submits a block for asynchronous execution on the socketQueue
			dispatch_async(socketQueue, ^{
				NSAutoreleasePool *callbackPool = [[NSAutoreleasePool alloc] init];
				
				[self doWriteTimeoutWithExtension:timeoutExtension];
				
				[callbackPool drain];
			}); // END OF BLOCK
			
			[delegatePool drain];
		}); // END OF BLOCK
	}
	else
	{
		[self doWriteTimeoutWithExtension:0.0];
	}
}


/*
    param NSTimeInterval
*/ 
- (void)doWriteTimeoutWithExtension:(NSTimeInterval)timeoutExtension
{
    // if currently writing
	if (currentWrite)
	{
		if (timeoutExtension > 0.0)
		{
			currentWrite->timeout += timeoutExtension;
			
			// Reschedule the timer
			dispatch_time_t tt = dispatch_time(DISPATCH_TIME_NOW, (timeoutExtension * NSEC_PER_SEC));
			dispatch_source_set_timer(writeTimer, tt, DISPATCH_TIME_FOREVER, 0);
			
			// Unpause writes, and continue
			flags &= ~kWritesPaused;
			[self doWriteData];
		}
		else
		{
			LogVerbose(@"WriteTimeout");
			
			[self closeWithError:[self writeTimeoutError]];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


/*
    Start transport layer security with specific settings
    param NSDictionary
*/
- (void)startTLS:(NSDictionary *)tlsSettings
{
	LogTrace();
	
	if (tlsSettings == nil)
    {
        // Passing nil/NULL to CFReadStreamSetProperty will appear to work the same as passing an empty dictionary,
        // but causes problems if we later try to fetch the remote host's certificate.
        // 
        // To be exact, it causes the following to return NULL instead of the normal result:
        // CFReadStreamCopyProperty(readStream, kCFStreamPropertySSLPeerCertificates)
        // 
        // So we use an empty dictionary instead, which works perfectly.
        
        tlsSettings = [NSDictionary dictionary];
    }
	
	GCDAsyncSpecialPacket *packet = [[GCDAsyncSpecialPacket alloc] initWithTLSSettings:tlsSettings];
	
    // Submits a block for asynchronous execution on the socketQueue
	dispatch_async(socketQueue, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		if ((flags & kSocketStarted) && !(flags & kQueuedTLS) && !(flags & kForbidReadsWrites))
		{
			[readQueue addObject:packet];
			[writeQueue addObject:packet];
			
			flags |= kQueuedTLS;
			
			[self maybeDequeueRead];
			[self maybeDequeueWrite];
		}
		
		[pool drain];
	}); // END OF BLOCK
	
	[packet release];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security - Mac OS X
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#if !TARGET_OS_IPHONE

/*
    param buffer
    param size_t
    returns OSStatus
*/
- (OSStatus)sslReadWithBuffer:(void *)buffer length:(size_t *)bufferLength
{
	LogVerbose(@"sslReadWithBuffer:%p length:%lu", buffer, (unsigned long)*bufferLength);
	
	if ((socketFDBytesAvailable == 0) && ([sslReadBuffer length] == 0))
	{
		LogVerbose(@"%@ - No data available to read...", THIS_METHOD);
		
		// No data available to read.
		// 
		// Need to wait for readSource to fire and notify us of
		// available data in the socket's internal read buffer.
		
		[self resumeReadSource];
		
		*bufferLength = 0;
		return errSSLWouldBlock;
	}
	
	size_t totalBytesLeft = *bufferLength;
	size_t totalBytesRead = 0;
	
	BOOL done = NO;
	BOOL socketError = NO;
	
	// 
	// STEP 1 : READ FROM SSL PRE BUFFER
	// 
	
	NSUInteger sslReadBufferLength = [sslReadBuffer length];
	
	if (sslReadBufferLength > 0)
	{
		size_t bytesToCopy = (size_t)((sslReadBufferLength > totalBytesLeft) ? totalBytesLeft : sslReadBufferLength);
		
		LogVerbose(@"Copying %u bytes from sslReadBuffer", (unsigned)bytesToCopy);
		
		memcpy(buffer, [sslReadBuffer mutableBytes], bytesToCopy);
		
		[sslReadBuffer replaceBytesInRange:NSMakeRange(0, bytesToCopy) withBytes:NULL length:0];
		
		LogVerbose(@"sslReadBuffer.length = %lu", (unsigned long)[sslReadBuffer length]);
		
		totalBytesLeft -= bytesToCopy;
		totalBytesRead += bytesToCopy;
		
		done = (totalBytesLeft == 0);
		
		if (done) LogVerbose(@"SSLRead complete");
	}
	
	// 
	// STEP 2 : READ FROM SOCKET
	// 
	
	if (!done && (socketFDBytesAvailable > 0))
	{
		int socketFD = (socket6FD == SOCKET_NULL) ? socket4FD : socket6FD;
		
		BOOL readIntoPreBuffer;
		size_t bytesToRead;
		void *buf;
		
		if (socketFDBytesAvailable > totalBytesLeft)
		{
			// Read all available data from socket into sslReadBuffer.
			// Then copy requested amount into dataBuffer.
			
			if ([sslReadBuffer length] < socketFDBytesAvailable)
			{
				[sslReadBuffer setLength:socketFDBytesAvailable];
			}
			
			LogVerbose(@"Reading into sslReadBuffer...");
			
			readIntoPreBuffer = YES;
			bytesToRead = (size_t)socketFDBytesAvailable;
			buf = [sslReadBuffer mutableBytes];
		}
		else
		{
			// Read available data from socket directly into dataBuffer.
			
			readIntoPreBuffer = NO;
			bytesToRead = totalBytesLeft;
			buf = buffer + totalBytesRead;
		}
		
		ssize_t result = read(socketFD, buf, bytesToRead);
		LogVerbose(@"read from socket = %i", (int)result);
		
		if (result < 0)
		{
			LogVerbose(@"read errno = %i", errno);
			
			if (errno != EWOULDBLOCK)
			{
				socketError = YES;
			}
			
			socketFDBytesAvailable = 0;
			
			if (readIntoPreBuffer)
			{
				[sslReadBuffer setLength:0];
			}
		}
		else if (result == 0)
		{
			socketError = YES;
			socketFDBytesAvailable = 0;
			
			if (readIntoPreBuffer)
			{
				[sslReadBuffer setLength:0];
			}
		}
		else
		{
			ssize_t bytesReadFromSocket = result;
			
			if (socketFDBytesAvailable > bytesReadFromSocket)
            {
				socketFDBytesAvailable -= bytesReadFromSocket;
			}else{
				socketFDBytesAvailable = 0;
			}
            
			if (readIntoPreBuffer)
			{
				size_t bytesToCopy = MIN(totalBytesLeft, bytesReadFromSocket);
				
				LogVerbose(@"Copying %u bytes from sslReadBuffer", (unsigned)bytesToCopy);
				
				memcpy(buffer + totalBytesRead, [sslReadBuffer bytes], bytesToCopy);
				
				[sslReadBuffer setLength:bytesReadFromSocket];
				[sslReadBuffer replaceBytesInRange:NSMakeRange(0, bytesToCopy) withBytes:NULL length:0];
				
				totalBytesLeft -= bytesToCopy;
				totalBytesRead += bytesToCopy;
				
				LogVerbose(@"sslReadBuffer.length = %lu", (unsigned long)[sslReadBuffer length]);
			}
			else
			{
				totalBytesLeft -= bytesReadFromSocket;
				totalBytesRead += bytesReadFromSocket;
			}
			
			done = (totalBytesLeft == 0);
			
			if (done) LogVerbose(@"SSLRead complete");
		}
	}
	
	*bufferLength = totalBytesRead;
	
	if (done)
    {
		return noErr;
	}
    
	if (socketError)
    {
		return errSSLClosedAbort;
	}
    
	return errSSLWouldBlock;
}


/*
    param buffer
    param size_t
    returns OSStatus
*/
- (OSStatus)sslWriteWithBuffer:(const void *)buffer length:(size_t *)bufferLength
{
	if (!(flags & kSocketCanAcceptBytes))
	{
		// Unable to write.
		// 
		// Need to wait for writeSource to fire and notify us of
		// available space in the socket's internal write buffer.
		
		[self resumeWriteSource];
		
		*bufferLength = 0;
		return errSSLWouldBlock;
	}
	
	size_t bytesToWrite = *bufferLength;
	size_t bytesWritten = 0;
	
	BOOL done = NO;
	BOOL socketError = NO;
	
	int socketFD = (socket4FD == SOCKET_NULL) ? socket6FD : socket4FD;
	
	ssize_t result = write(socketFD, buffer, bytesToWrite);
	
	if (result < 0)
	{
		if (errno != EWOULDBLOCK)
		{
			socketError = YES;
		}
		
		flags &= ~kSocketCanAcceptBytes;
	}
	else if (result == 0)
	{
		flags &= ~kSocketCanAcceptBytes;
	}
	else
	{
		bytesWritten = result;
		
		done = (bytesWritten == bytesToWrite);
	}
	
	*bufferLength = bytesWritten;
	
	if (done)
    {
		return noErr;
	}
    
	if (socketError)
    {
		return errSSLClosedAbort;
	}
    
	return errSSLWouldBlock;
}

/*
    param SSLConnectionRef
    param data
    param size_t
    returns OSStatus
*/
OSStatus SSLReadFunction(SSLConnectionRef connection, void *data, size_t *dataLength)
{
	GCDAsyncSocket *asyncSocket = (GCDAsyncSocket *)connection;
	
	NSCAssert(dispatch_get_current_queue() == asyncSocket->socketQueue, @"What the deuce?");
	
	return [asyncSocket sslReadWithBuffer:data length:dataLength];
}



/*
    param SSLConnectionRef
    param data
    param size_t
    returns OSStatus
*/
OSStatus SSLWriteFunction(SSLConnectionRef connection, const void *data, size_t *dataLength)
{
	GCDAsyncSocket *asyncSocket = (GCDAsyncSocket *)connection;
	
	NSCAssert(dispatch_get_current_queue() == asyncSocket->socketQueue, @"What the deuce?");
	
	return [asyncSocket sslWriteWithBuffer:data length:dataLength];
}

/*
    Check whether can start transport layer security
*/
- (void)maybeStartTLS
{
	LogTrace();
	
	// We can't start TLS until:
	// - All queued reads prior to the user calling startTLS are complete
	// - All queued writes prior to the user calling startTLS are complete
	// 
	// We'll know these conditions are met when both kStartingReadTLS and kStartingWriteTLS are set
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		LogVerbose(@"Starting TLS...");
		
		OSStatus status;
		
		GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
		NSDictionary *tlsSettings = tlsPacket->tlsSettings;
		
		// Create SSLContext, and setup IO callbacks and connection ref
		
		BOOL isServer = [[tlsSettings objectForKey:(NSString *)kCFStreamSSLIsServer] boolValue];
		
		status = SSLNewContext(isServer, &sslContext);

		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLNewContext"]];
			return;
		}
		
		status = SSLSetIOFuncs(sslContext, &SSLReadFunction, &SSLWriteFunction);

		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetIOFuncs"]];
			return;
		}
		
		status = SSLSetConnection(sslContext, (SSLConnectionRef)self);

		if (status != noErr)
		{
			[self closeWithError:[self otherError:@"Error in SSLSetConnection"]];
			return;
		}
		
		// Configure SSLContext from given settings
		// 
		// Checklist:
		// 1. kCFStreamSSLPeerName
		// 2. kCFStreamSSLAllowsAnyRoot
		// 3. kCFStreamSSLAllowsExpiredRoots
		// 4. kCFStreamSSLValidatesCertificateChain
		// 5. kCFStreamSSLAllowsExpiredCertificates
		// 6. kCFStreamSSLCertificates
		// 7. kCFStreamSSLLevel
		// 8. GCDAsyncSocketSSLCipherSuites
		// 9. GCDAsyncSocketSSLDiffieHellmanParameters
		
		id value;
		
		// 1. kCFStreamSSLPeerName
		
		value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLPeerName];

		if ([value isKindOfClass:[NSString class]])
		{
			NSString *peerName = (NSString *)value;
			
			const char *peer = [peerName UTF8String];
			size_t peerLen = strlen(peer);
			
			status = SSLSetPeerDomainName(sslContext, peer, peerLen);

			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetPeerDomainName"]];
				return;
			}
		}
		
		// 2. kCFStreamSSLAllowsAnyRoot
		
		value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsAnyRoot];

		if (value)
		{
			BOOL allowsAnyRoot = [value boolValue];
			
			status = SSLSetAllowsAnyRoot(sslContext, allowsAnyRoot);

			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetAllowsAnyRoot"]];
				return;
			}
		}
		
		// 3. kCFStreamSSLAllowsExpiredRoots
		
		value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsExpiredRoots];

		if (value)
		{
			BOOL allowsExpiredRoots = [value boolValue];
			
			status = SSLSetAllowsExpiredRoots(sslContext, allowsExpiredRoots);

			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetAllowsExpiredRoots"]];
				return;
			}
		}
		
		// 4. kCFStreamSSLValidatesCertificateChain
		
		value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLValidatesCertificateChain];

		if (value)
		{
			BOOL validatesCertChain = [value boolValue];
			
			status = SSLSetEnableCertVerify(sslContext, validatesCertChain);

			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetEnableCertVerify"]];
				return;
			}
		}
		
		// 5. kCFStreamSSLAllowsExpiredCertificates
		
		value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLAllowsExpiredCertificates];

		if (value)
		{
			BOOL allowsExpiredCerts = [value boolValue];
			
			status = SSLSetAllowsExpiredCerts(sslContext, allowsExpiredCerts);

			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetAllowsExpiredCerts"]];
				return;
			}
		}
		
		// 6. kCFStreamSSLCertificates
		
		value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLCertificates];

		if (value)
		{
			CFArrayRef certs = (CFArrayRef)value;
			
			status = SSLSetCertificate(sslContext, certs);

			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetCertificate"]];
				return;
			}
		}
		
		// 7. kCFStreamSSLLevel
		
		value = [tlsSettings objectForKey:(NSString *)kCFStreamSSLLevel];

		if (value)
		{
			NSString *sslLevel = (NSString *)value;
			
			if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelSSLv2])
			{
				// kCFStreamSocketSecurityLevelSSLv2:
				// 
				// Specifies that SSL version 2 be set as the security protocol.
				
				SSLSetProtocolVersionEnabled(sslContext, kSSLProtocolAll, NO);
				SSLSetProtocolVersionEnabled(sslContext, kSSLProtocol2,   YES);
			}
			else if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelSSLv3])
			{
				// kCFStreamSocketSecurityLevelSSLv3:
				// 
				// Specifies that SSL version 3 be set as the security protocol.
				// If SSL version 3 is not available, specifies that SSL version 2 be set as the security protocol.
				
				SSLSetProtocolVersionEnabled(sslContext, kSSLProtocolAll, NO);
				SSLSetProtocolVersionEnabled(sslContext, kSSLProtocol2,   YES);
				SSLSetProtocolVersionEnabled(sslContext, kSSLProtocol3,   YES);
			}
			else if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelTLSv1])
			{
				// kCFStreamSocketSecurityLevelTLSv1:
				// 
				// Specifies that TLS version 1 be set as the security protocol.
				
				SSLSetProtocolVersionEnabled(sslContext, kSSLProtocolAll, NO);
				SSLSetProtocolVersionEnabled(sslContext, kTLSProtocol1,   YES);
			}
			else if ([sslLevel isEqualToString:(NSString *)kCFStreamSocketSecurityLevelNegotiatedSSL])
			{
				// kCFStreamSocketSecurityLevelNegotiatedSSL:
				// 
				// Specifies that the highest level security protocol that can be negotiated be used.
				
				SSLSetProtocolVersionEnabled(sslContext, kSSLProtocolAll, YES);
			}
		}
		
		// 8. GCDAsyncSocketSSLCipherSuites
		
		value = [tlsSettings objectForKey:GCDAsyncSocketSSLCipherSuites];

		if (value)
		{
			NSArray *cipherSuites = (NSArray *)value;
			NSUInteger numberCiphers = [cipherSuites count];
			SSLCipherSuite ciphers[numberCiphers];
			
			NSUInteger cipherIndex;

			for (cipherIndex = 0; cipherIndex < numberCiphers; cipherIndex++)
			{
				NSNumber *cipherObject = [cipherSuites objectAtIndex:cipherIndex];
				ciphers[cipherIndex] = [cipherObject shortValue];
			}
			
			status = SSLSetEnabledCiphers(sslContext, ciphers, numberCiphers);

			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetEnabledCiphers"]];
				return;
			}
		}
		
		// 9. GCDAsyncSocketSSLDiffieHellmanParameters
		
		value = [tlsSettings objectForKey:GCDAsyncSocketSSLDiffieHellmanParameters];

		if (value)
		{
			NSData *diffieHellmanData = (NSData *)value;
			
			status = SSLSetDiffieHellmanParams(sslContext, [diffieHellmanData bytes], [diffieHellmanData length]);

			if (status != noErr)
			{
				[self closeWithError:[self otherError:@"Error in SSLSetDiffieHellmanParams"]];
				return;
			}
		}
		
		// Setup the sslReadBuffer
		// 
		// If there is any data in the partialReadBuffer,
		// this needs to be moved into the sslReadBuffer,
		// as this data is now part of the secure read stream.
		
		sslReadBuffer = [[NSMutableData alloc] init];
		
		if ([partialReadBuffer length] > 0)
		{
			[sslReadBuffer appendData:partialReadBuffer];
			[partialReadBuffer setLength:0];
		}
		
		// Start the SSL Handshake process
		
		[self continueSSLHandshake];
	}
}

/*
    Continue SSL handshake
*/
- (void)continueSSLHandshake
{
	LogTrace();
	
	// If the return value is noErr, the session is ready for normal secure communication.
	// If the return value is errSSLWouldBlock, the SSLHandshake function must be called again.
	// Otherwise, the return value indicates an error code.
	
	OSStatus status = SSLHandshake(sslContext);
	
    // if there is not an error
	if (status == noErr)
	{
		LogVerbose(@"SSLHandshake complete");
		
        
        // If set, we're waiting for TLS negotiation to complete
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
        
        // If set, socket is using secure communication via SSL/TLS
		flags |=  kSocketSecure;
		
        
		if (delegateQueue && [delegate respondsToSelector:@selector(socketDidSecure:)])
		{
			id theDelegate = delegate;
			
            // Submits a block for asynchronous execution on the delegateQueue
			dispatch_async(delegateQueue, ^{
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
				[theDelegate socketDidSecure:self];
				
				[pool drain];
			}); // END OF BLOCK
		}
		
        // End current read and write
		[self endCurrentRead];
        
        // Cancel the timer and release the current writer
		[self endCurrentWrite]; 
		
        
        // Possibly dequeue the read and write
		[self maybeDequeueRead];
		[self maybeDequeueWrite];
	}
	else if (status == errSSLWouldBlock)
	{
		LogVerbose(@"SSLHandshake continues...");
		
		// Handshake continues...
		// 
		// This method will be called again from doReadData or doWriteData.
	}
	else
	{
		[self closeWithError:[self sslError:status]];
	}
}

#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Security - iOS
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#if TARGET_OS_IPHONE

/*
    Class method
    Start SSL handshake thread if needed
*/
+ (void)startHandshakeThreadIfNeeded
{
	static dispatch_once_t predicate;
	
    
	dispatch_once(&predicate, ^{
		
		sslHandshakeThread = [[NSThread alloc] initWithTarget:self
		                                             selector:@selector(sslHandshakeThread)
		                                               object:nil];
		[sslHandshakeThread start];
	}); // END OF BLOCK
}


/*
    Class method
    The ssl handshake thread
*/
+ (void)sslHandshakeThread
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	LogInfo(@"SSLHandshakeThread: Started");
	
	// We can't run the run loop unless it has an associated input source or a timer.
	// So we'll just create a timer that will never fire - unless the server runs for 10,000 years.
	[NSTimer scheduledTimerWithTimeInterval:DBL_MAX target:self selector:@selector(ignore:) userInfo:nil repeats:NO];
	
    
    // Returns the NSRunLoop object for the current thread then 
    // executes the run command which puts the receiver into a 
    // permanent loop, during which time it processes data from 
    // all attached input sources.
	[[NSRunLoop currentRunLoop] run];
	
	LogInfo(@"SSLHandshakeThread: Stopped");
	
	[pool release];
}


/*
    Class method
    Add handshake listener
    param GCDAsyncSocket
*/
+ (void)addHandshakeListener:(GCDAsyncSocket *)asyncSocket
{
	LogTrace();
	
    // Returns the CFRunLoop object for the current thread.
	CFRunLoopRef runLoop = CFRunLoopGetCurrent();
	
    
    // Note: another was of writing if ((*asyncSocket).readStream)
	if (asyncSocket->readStream)
    {
		CFReadStreamScheduleWithRunLoop(asyncSocket->readStream, runLoop, kCFRunLoopDefaultMode);
	}
    
    // Note: another was of writing if ((*asyncSocket).writeStream)
	if (asyncSocket->writeStream)
    {
		CFWriteStreamScheduleWithRunLoop(asyncSocket->writeStream, runLoop, kCFRunLoopDefaultMode);
    }
}


/*
    Class method
    Remove the handshake listener
    param GCDAsyncSocket
*/
+ (void)removeHandshakeListener:(GCDAsyncSocket *)asyncSocket
{
	LogTrace();
	
    // Returns the CFRunLoop object for the current thread.
	CFRunLoopRef runLoop = CFRunLoopGetCurrent();
	
    // Note: another was of writing if ((*asyncSocket).readStream)
	if (asyncSocket->readStream)
    {
		CFReadStreamUnscheduleFromRunLoop(asyncSocket->readStream, runLoop, kCFRunLoopDefaultMode);
	}
    
    // Note: another was of writing if ((*asyncSocket).writeStream)
	if (asyncSocket->writeStream)
    {
		CFWriteStreamUnscheduleFromRunLoop(asyncSocket->writeStream, runLoop, kCFRunLoopDefaultMode);
    }
}


/*
    Finish the SSL handshake
*/
- (void)finishSSLHandshake
{
	LogTrace();
	
    
    // If set, we're waiting for TLS negotiation to complete
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
        
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
        // If set, socket is using secure communication via SSL/TLS
		flags |= kSocketSecure;
		
        
        // If there is a delegate queue and it has a socketDidSecure method
		if (delegateQueue && [delegate respondsToSelector:@selector(socketDidSecure:)])
		{
            
            // Local variable as pointer to delegate
			id theDelegate = delegate;
		
            // Submits a block for asynchronous execution on the delegateQueue
			dispatch_async(delegateQueue, ^{
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
				[theDelegate socketDidSecure:self];
				
				[pool release];
			}); // END OF BLOCK
		}
		
        // Stops the readtimer and releases the currentRead
		[self endCurrentRead];
        
        // Cancel the timer and release the current writer
		[self endCurrentWrite];
		
        // handles auto-disconnect post read/write completion
		[self maybeDequeueRead];
		[self maybeDequeueWrite];
	}
}


/*
    Abort the SSL handshake
    param NSError
*/
- (void)abortSSLHandshake:(NSError *)error
{
	LogTrace();
	
    // If set, we're waiting for TLS negotiation to complete
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		flags &= ~kStartingReadTLS;
		flags &= ~kStartingWriteTLS;
		
		[self closeWithError:error];
	}
}


/*
    Create readStream callback
    param CFReadStreamRef
    param CRStreamEventType
    param pInfo
*/
static void CFReadStreamCallback (CFReadStreamRef stream, CFStreamEventType type, void *pInfo)
{
    
	GCDAsyncSocket *asyncSocket = [(GCDAsyncSocket *)pInfo retain];
	
    
    // Switch based on the type of stream event
	switch(type)
	{
		case kCFStreamEventHasBytesAvailable:
		{
            // Note: sames as (*asyncSocket).socketQueue
			dispatch_async(asyncSocket->socketQueue, ^{
				
				LogCVerbose(@"CFReadStreamCallback - HasBytesAvailable");
				
                // Note: same as (*asyncSocket).readStream
				if (asyncSocket->readStream != stream)
					return_from_block;
				
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
                // Note: sames as (*asyncSocket).flags
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					asyncSocket->flags |= kSecureSocketHasBytesAvailable;
					[asyncSocket finishSSLHandshake];
				}
				else
				{
					asyncSocket->flags |= kSecureSocketHasBytesAvailable;
					[asyncSocket doReadData];
				}
				
				[pool release];
			});
			
			break;
		}
		default:
		{
			NSError *error = NSMakeCollectable(CFReadStreamCopyError(stream));
			
            // Submits a block for asynchronous execution on the socketQueue
			dispatch_async(asyncSocket->socketQueue, ^{
				
				LogCVerbose(@"CFReadStreamCallback - Other");
				
				if (asyncSocket->readStream != stream)
					return_from_block;
				
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					[asyncSocket abortSSLHandshake:error];
				}
				else
				{
					[asyncSocket closeWithError:error];
				}
				
				[pool release];
			}); // END OF BLOCK
			
			[error release];
			break;
		}
	}
	
	[asyncSocket release];
}


/*
    Create stream callback
    param CFWriteStreamRef
    param CFStreamEventType
    param pInfo
*/
static void CFWriteStreamCallback (CFWriteStreamRef stream, CFStreamEventType type, void *pInfo)
{
	GCDAsyncSocket *asyncSocket = [(GCDAsyncSocket *)pInfo retain];
	
    
    // Switch based on the stream event
	switch(type)
	{
		case kCFStreamEventCanAcceptBytes:
		{
            
            // Submits a block for asynchronous execution on the socketQueue
			dispatch_async(asyncSocket->socketQueue, ^{
				
				LogCVerbose(@"CFWriteStreamCallback - CanAcceptBytes");
				
				if (asyncSocket->writeStream != stream)
                {
					return_from_block;
				}
                
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					asyncSocket->flags |= kSocketCanAcceptBytes;
					[asyncSocket finishSSLHandshake];
				}
				else
				{
					asyncSocket->flags |= kSocketCanAcceptBytes;
					[asyncSocket doWriteData];
				}
				
				[pool release];
			}); // END OF BLOCK
			
			break;
		}
		default:
		{
			NSError *error = NSMakeCollectable(CFWriteStreamCopyError(stream));
			
            
            // Submits a block for asynchronous execution on the socketQueue
			dispatch_async(asyncSocket->socketQueue, ^{
				
				LogCVerbose(@"CFWriteStreamCallback - Other");
				
				if (asyncSocket->writeStream != stream)
                {
					return_from_block;
				}
                
				NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
				
				if ((asyncSocket->flags & kStartingReadTLS) && (asyncSocket->flags & kStartingWriteTLS))
				{
					[asyncSocket abortSSLHandshake:error];
				}
				else
				{
					[asyncSocket closeWithError:error];
				}
				
				[pool release];
			}); // END OF BLOCK
			
			[error release];
			break;
		}
	}
	
	[asyncSocket release];
}


/*
    Create read and write stream
    returns BOOL
*/
- (BOOL)createReadAndWriteStream
{
    
    // Check to make sure the values are what they are suppose to be.  
    // Thus read and write streams should be null when creating.  
	NSAssert((readStream == NULL && writeStream == NULL), @"Read/Write stream not null");
	
    
    // Set whether socket file description is IP version 4 or 6
	int socketFD = (socket6FD == SOCKET_NULL) ? socket4FD : socket6FD;
	
    
    // Whether created a socket or not
	if (socketFD == SOCKET_NULL)
	{
		return NO;
	}
	
	LogVerbose(@"Creating read and write stream...");
	
    /* Socket streams; the returned streams are paired such that they use the same socket; pass NULL if you want only the read stream or the write stream */
	CFStreamCreatePairWithSocket(NULL, (CFSocketNativeHandle)socketFD, &readStream, &writeStream);
	
    
	// The kCFStreamPropertyShouldCloseNativeSocket property should be false by default (for our case).
	// But let's not take any chances.
	
	if (readStream)
    {
        /* Returns TRUE if the stream recognizes and accepts the given property-value pair; 
         FALSE otherwise. */
		CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
    }
	
    
    
    if (writeStream)
    {
        
        /* Returns TRUE if the stream recognizes and accepts the given property-value pair; 
         FALSE otherwise. */
		CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
    }
	
    // Check whether the read and write streams were created
	if ((readStream == NULL) || (writeStream == NULL))
	{
		LogWarn(@"Unable to create read and write stream...");
		
		if (readStream)
		{
            /* Terminates the flow of bytes; releases any system resources required by the stream.  The stream may not fail to close.  You may call CFStreamClose() to effectively abort a stream. */
			CFReadStreamClose(readStream);
            
            
			CFRelease(readStream);
			readStream = NULL;
		}
		if (writeStream)
		{
            /* Terminates the flow of bytes; releases any system resources required by the stream.  The stream may not fail to close.  You may call CFStreamClose() to effectively abort a stream. */
			CFWriteStreamClose(writeStream);
			CFRelease(writeStream);
			writeStream = NULL;
		}
		
		return NO;
	}
	
    // Were able to create read and write streams
	return YES;
}


/*
    Check if can start transport layer security
*/
- (void)maybeStartTLS
{
	LogTrace();
	
	// We can't start TLS until:
	// - All queued reads prior to the user calling startTLS are complete
	// - All queued writes prior to the user calling startTLS are complete
	// 
	// We'll know these conditions are met when both kStartingReadTLS and kStartingWriteTLS are set
	
	if ((flags & kStartingReadTLS) && (flags & kStartingWriteTLS))
	{
		LogVerbose(@"Starting TLS...");
		
        
        // If the partialReadBuffer has data
		if ([partialReadBuffer length] > 0)
		{
			NSString *msg = @"Invalid TLS transition. Handshake has already been read from socket.";
			
			[self closeWithError:[self otherError:msg]];
			return;
		}
		
        
		[self suspendReadSource];
		[self suspendWriteSource];
		
        
		socketFDBytesAvailable = 0;
		flags &= ~kSocketCanAcceptBytes;
		flags &= ~kSecureSocketHasBytesAvailable;
		
		if (readStream == NULL || writeStream == NULL)
		{
			if (![self createReadAndWriteStream])
			{
				[self closeWithError:[self otherError:@"Error in CFStreamCreatePairWithSocket"]];
				return;
			}
		}
		
		streamContext.version = 0;
		streamContext.info = self;
		streamContext.retain = nil;
		streamContext.release = nil;
		streamContext.copyDescription = nil;
		
		CFOptionFlags readStreamEvents = kCFStreamEventHasBytesAvailable |
		                                 kCFStreamEventErrorOccurred     |
		                                 kCFStreamEventEndEncountered    ;
		
        
        // Try to register a client to hear about interesting events that occur on a stream.  Only one client per stream is allowed; registering a new client replaces the previous one.
		if (!CFReadStreamSetClient(readStream, readStreamEvents, &CFReadStreamCallback, &streamContext))
		{
			[self closeWithError:[self otherError:@"Error in CFReadStreamSetClient"]];
			return;
		}
        
		
		CFOptionFlags writeStreamEvents = kCFStreamEventCanAcceptBytes |
		                                  kCFStreamEventErrorOccurred  |
		                                  kCFStreamEventEndEncountered ;
		
        
        // Try to register a client to hear about interesting events that occur on a stream.  Only one client per stream is allowed; registering a new client replaces the previous one.        
		if (!CFWriteStreamSetClient(writeStream, writeStreamEvents, &CFWriteStreamCallback, &streamContext))
		{
			[self closeWithError:[self otherError:@"Error in CFWriteStreamSetClient"]];
			return;
		}
		
		[[self class] startHandshakeThreadIfNeeded];
		[[self class] performSelector:@selector(addHandshakeListener:)
		                     onThread:sslHandshakeThread
		                   withObject:self
		                waitUntilDone:YES];
		
		flags |= kAddedHandshakeListener;
		
		NSAssert([currentRead isKindOfClass:[GCDAsyncSpecialPacket class]], @"Invalid read packet for startTLS");
		NSAssert([currentWrite isKindOfClass:[GCDAsyncSpecialPacket class]], @"Invalid write packet for startTLS");
		
		GCDAsyncSpecialPacket *tlsPacket = (GCDAsyncSpecialPacket *)currentRead;
		NSDictionary *tlsSettings = tlsPacket->tlsSettings;
		
		// Getting an error concerning kCFStreamPropertySSLSettings ?
		// You need to add the CFNetwork framework to your iOS application.
		
        
        /* Returns TRUE if the stream recognizes and accepts the given property-value pair; 
         FALSE otherwise. */
		BOOL r1 = CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, (CFDictionaryRef)tlsSettings);
        
        
        /* Returns TRUE if the stream recognizes and accepts the given property-value pair; 
         FALSE otherwise. */
		BOOL r2 = CFWriteStreamSetProperty(writeStream, kCFStreamPropertySSLSettings, (CFDictionaryRef)tlsSettings);
		
        
        
		if (!r1 || !r2)
		{
			[self closeWithError:[self otherError:@"Error in CFStreamSetProperty"]];
			return;
		}
		
		CFStreamStatus readStatus = CFReadStreamGetStatus(readStream);
		CFStreamStatus writeStatus = CFWriteStreamGetStatus(writeStream);
		
		if ((readStatus == kCFStreamStatusNotOpen) || (writeStatus == kCFStreamStatusNotOpen))
		{
			r1 = CFReadStreamOpen(readStream);
			r2 = CFWriteStreamOpen(writeStream);
			
			if (!r1 || !r2)
			{
				[self closeWithError:[self otherError:@"Error in CFStreamOpen"]];
			}
		}
		
		LogVerbose(@"Waiting for SSL Handshake to complete...");
	}
}

#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Advanced
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


/*
    Performs a block on the socketQueue
 
 It's not thread-safe to access certain variables from outside the socket's internal queue.
 For example, the socket file descriptor. File descriptors are simply integers which reference an index in the per-process file table. However, when one requests a new file descriptor (by opening a file or socket), the file descriptor returned is guaranteed to be the lowest numbered unused descriptor. So if we're not careful, the following could be possible:
 Thread A invokes a method which returns the socket's file descriptor.
 The socket is closed via the socket's internal queue on thread B.
 Thread C opens a file, and subsequently receives the file descriptor that was previously the socket's FD.
 Thread A is now accessing/altering the file instead of the socket.
 In addition to this, other variables are not actually objects, and thus cannot be retained/released or even autoreleased. An example is the sslContext, of type SSLContextRef, which is actually a malloc'd struct.
 Although there are internal variables that make it difficult to maintain thread-safety, it is important to provide access to these variables to ensure this class can be used in a wide array of environments. This can be accomplished by invoking a block on the socket's internal queue. The methods below can be invoked from within the block to access those generally thread-unsafe internal variables in a thread-safe manner. The given block will be invoked synchronously on the socket's internal queue.
 If you save references to any protected variables and use them outside the block, you do so at your own peril.
 */
- (void)performBlock:(dispatch_block_t)block
{
    // Submits a block for synchronous execution on the socketQueue.
	dispatch_sync(socketQueue, block);
}


/*
    Get socket file descriptor
    This method is only available from within the context of a performBlock: invocation. See the documentation for the performBlock: method above.
    Provides access to the socket's file descriptor.
    This method is typically used for outgoing client connections. If the socket is a server socket (is accepting incoming connections), it might actually have multiple internal socket file descriptors - one for IPv4 and one for IPv6.
    Returns -1 if the socket is disconnected.
*/
- (int)socketFD
{
    
    // Returns the queue on which the currently executing block is running.
	if (dispatch_get_current_queue() == socketQueue)
	{
		if (socket4FD != SOCKET_NULL)
        {
			return socket4FD;
		}else{ // if the IP version 4 socket file descriptor is null then return the IP version 6 file descriptor
			return socket6FD;
        }
	}
	else // if the current queue is not the socketQueue
	{
		return SOCKET_NULL;
	}
}


/*
    Get an IP version 4 protocol file descriptor
    This method is only available from within the context of a performBlock: invocation. See the documentation for the performBlock: method above.
    Provides access to the socket's file descriptor (if IPv4 is being used).
    If the socket is a server socket (is accepting incoming connections), it might actually have multiple internal socket file descriptors - one for IPv4 and one for IPv6.
    Returns -1 if the socket is disconnected, or if IPv4 is not being used.
*/
- (int)socket4FD
{
    // Returns the queue on which the currently executing block is running.
	if (dispatch_get_current_queue() == socketQueue)
    {
        // Return the IP version 4 socket file descriptor
		return socket4FD;
	}else{ // if the current queue is not the socketQueue
		return SOCKET_NULL;
    }
}


/*
    Get an IP version 6 protocol file descriptor
    This method is only available from within the context of a performBlock: invocation. See the documentation for the performBlock: method above.
    Provides access to the socket's file descriptor (if IPv6 is being used).
    If the socket is a server socket (is accepting incoming connections), it might actually have multiple internal socket file descriptors - one for IPv4 and one for IPv6.
    Returns -1 if the socket is disconnected, or if IPv6 is not being used.
*/
- (int)socket6FD
{
    // Returns the queue on which the currently executing block is running.
	if (dispatch_get_current_queue() == socketQueue)
    {
        // Return the IP version 6 socket file descriptor
		return socket6FD;
	}else{ // If the current queue is not the socketQueue
		return SOCKET_NULL;
    }
}

#if TARGET_OS_IPHONE


/*
    Get a readStream
    This method is only available on iOS (TARGET_OS_IPHONE).
    This method is only available from within the context of a performBlock: invocation. See the documentation for the performBlock: method above.
    Provides access to the socket's internal CFReadStream (if SSL/TLS has been started on the socket).
 
*/
- (CFReadStreamRef)readStream
{
    // Returns the queue on which the currently executing block is running.
	if (dispatch_get_current_queue() == socketQueue)
	{
		if (readStream == NULL)
        {
            // Create the read and write stream
			[self createReadAndWriteStream];
        }
		
		return readStream;
	}
	else // If the current queue is not the socketQueue
	{
		return NULL;
	}
}


/*
    Get a writeStream (only available on IOS)
 This method is only available from within the context of a performBlock: invocation. See the documentation for the performBlock: method above.
 Provides access to the socket's internal CFWriteStream (if SSL/TLS has been started on the socket).
 Note: Apple has decided to keep the SecureTransport framework private is iOS. This means the only supplied way to do SSL/TLS is via CFStream or some other API layered on top of it. Thus, in order to provide SSL/TLS support on iOS we are forced to rely on CFStream, instead of the preferred and more powerful SecureTransport. Read/write streams are only created if startTLS has been invoked to start SSL/TLS.
*/
- (CFWriteStreamRef)writeStream
{
    // Returns the queue on which the currently executing block is running.
	if (dispatch_get_current_queue() == socketQueue)
	{
		if (writeStream == NULL)
        {
            // Create the read and write stream
			[self createReadAndWriteStream];
        }
		
		return writeStream;
	}
	else // If the current queue is not the socketQueuue
	{
		return NULL;
	}
}



/*
    Whether to enable backgrounding on socket with caveat
    param BOOL
    returns BOOL
*/
- (BOOL)enableBackgroundingOnSocketWithCaveat:(BOOL)caveat
{
    // if the CFReadStream or CFWriteStream are NULL
	if (readStream == NULL || writeStream == NULL)
	{
        // Try and create a read and write stream
		if (![self createReadAndWriteStream])
		{
			// Error occured creating streams (perhaps socket isn't open)
			return NO;
		}
	}
	
    
	BOOL r1; // Whether can set read stream properties
    BOOL r2; // Whether can set write stream properties
	
	LogVerbose(@"Enabling backgrouding on socket");
	
    
    // /* Returns TRUE if the stream recognizes and accepts the given property-value pair; FALSE otherwise. */
	r1 = CFReadStreamSetProperty(readStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
	
    // /* Returns TRUE if the stream recognizes and accepts the given property-value pair; FALSE otherwise. */
    r2 = CFWriteStreamSetProperty(writeStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
	
    // Check if error setting stream properties
	if (!r1 || !r2)
	{
		LogError(@"Error setting voip type");
		return NO;
	}
	
	if (!caveat)
	{
        // Get the current status of the read stream
		CFStreamStatus readStatus = CFReadStreamGetStatus(readStream);
        
        // Get the current status of the write stream
		CFStreamStatus writeStatus = CFWriteStreamGetStatus(writeStream);
		
        // If the read or write streams are not open
		if ((readStatus == kCFStreamStatusNotOpen) || (writeStatus == kCFStreamStatusNotOpen))
		{
            // Open the read and write streams
			r1 = CFReadStreamOpen(readStream);
			r2 = CFWriteStreamOpen(writeStream);
			
            
            // Check if the read and write streams could be opened
			if (!r1 || !r2)
			{
				LogError(@"Error opening bg streams");
				return NO;
			}
		}
	}
	
	return YES;
}


/*
    Whether to enable backgrounding on socket
    returns boolean YES or NO
*/
- (BOOL)enableBackgroundingOnSocket
{
	LogTrace();
	
    // Returns the queue on which the currently executing block is running.
	if (dispatch_get_current_queue() == socketQueue)
	{
		return [self enableBackgroundingOnSocketWithCaveat:NO];
	}
	else // If the current queue is not the socketQueue
	{
		return NO;
	}
}


/*
    Whether to enable backgrouing on socket with caveat
    returns BOOL
*/
- (BOOL)enableBackgroundingOnSocketWithCaveat
{
	LogTrace();
	
    // Returns the queue on which the currently executing block is running.
	if (dispatch_get_current_queue() == socketQueue)
	{
		return [self enableBackgroundingOnSocketWithCaveat:YES];
	}
	else // If the current queue is not the socketQueue
	{
		return NO;
	}
}

#else


/*
    Gets the ssl context (Only available on Mac OSX, not iPhone)
    returns SSLContextRef
*/
- (SSLContextRef)sslContext
{
    // Returns the queue on which the currently executing block is running.
	if (dispatch_get_current_queue() == socketQueue)
    {
		return sslContext;
	}else{  // If the current queue is not the socketQueue
		return NULL;
    }
}

#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Class Methods
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


/*
    Class method
    Gets host from IP version 4 socket address
    param sockaddr_in
    returns NSString
*/
+ (NSString *)hostFromAddress4:(struct sockaddr_in *)pSockaddr4
{
    // Create an address buffer 16 characters in length
	char addrBuf[INET_ADDRSTRLEN];

    // Try to convert a numerical address into a text string suitable for presentation
	if (inet_ntop(AF_INET, &pSockaddr4->sin_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL)
	{
		addrBuf[0] = '\0';
	}

    // Returns a NSString from a CString with ASCII string encoding
	return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}


/*
    Class method
    Gets host from IP version 6 socket address
    param sockaddr_in6
    returns NSString
*/
+ (NSString *)hostFromAddress6:(struct sockaddr_in6 *)pSockaddr6
{
    
    // Create an address buffer 46 characters in length
	char addrBuf[INET6_ADDRSTRLEN]; // equals the number 46
	
    // Try to convert a numerical address into a text string suitable for presentation
	if (inet_ntop(AF_INET6, &pSockaddr6->sin6_addr, addrBuf, (socklen_t)sizeof(addrBuf)) == NULL)
	{
		addrBuf[0] = '\0';
	}
	
    // Returns a NSString from a CString with ASCII string encoding
	return [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
}


/*
    Class method
    Gets port from IP version 4 socket address
    param sockaddr_in 
    returns UInt16
*/
+ (UInt16)portFromAddress4:(struct sockaddr_in *)pSockaddr4
{
    // Converts a network address port to a host address port
	return ntohs(pSockaddr4->sin_port);
}

/*
    Class method
    Gets port from IP version 6 socket address
    param sockaddr_in6
    returns UInt16
*/
+ (UInt16)portFromAddress6:(struct sockaddr_in6 *)pSockaddr6
{
    // Converts a network address port to a host address port
	return ntohs(pSockaddr6->sin6_port);
}

/*
    Class method
    Returns the host from and NSData address
    param NSData
    returns NSString
*/
+ (NSString *)hostFromAddress:(NSData *)address
{
    // Local variable
	NSString *host;
	
    // Try to get the host from an address
	if ([self getHost:&host port:NULL fromAddress:address])
    {
		return host;
	}else{ // Could not get the host from the address
		return nil;
    }
}

/*
    Class method
    Gets the port from and address
    param NSData
    returns UInt16
*/
+ (UInt16)portFromAddress:(NSData *)address
{
    // Local variable
	UInt16 port;
	
    // Try to get the port from an address
	if ([self getHost:NULL port:&port fromAddress:address])
    {
		return port;
	}else{ // Can not get the port from an address
		return 0;
    }
}


/*
    Class method
    Gets the host and port from an address
    param NSString
    param UInt16
    param NSData
    returns BOOL
*/
+ (BOOL)getHost:(NSString **)hostPtr port:(UInt16 *)portPtr fromAddress:(NSData *)address
{
    // Check if address length is greater than sizoe of socket address
    // sockaddr is a structure used by kernel to store most addresses
    // Why:  To determine if the address is valid
	if ([address length] >= sizeof(struct sockaddr))
	{
        
        // Gets a pointer to the address contents.
		struct sockaddr *addrX = (struct sockaddr *)[address bytes];
		
        
        // If the socket address family is for an IP version 4 format
		if (addrX->sa_family == AF_INET)
		{
            // Check if the number of bytes in the address is greater than or equal to the size of a normal internet style socket address.  
			if ([address length] >= sizeof(struct sockaddr_in))
			{
                // Get the address from the pointer to the address
				struct sockaddr_in *addr4 = (struct sockaddr_in *)addrX;
				
                // Check if we can get the host from the address
				if (hostPtr) *hostPtr = [self hostFromAddress4:addr4];
                
                // Check if we can get the post from the address
				if (portPtr) *portPtr = [self portFromAddress4:addr4];
				
                
				return YES;
			}
		}
        // If the socket address family if for IP version 6 format
		else if (addrX->sa_family == AF_INET6)
		{
            
            // Check if the number of bytes in the address is greater than or equal to the size of a normal internet style socket address.  
			if ([address length] >= sizeof(struct sockaddr_in6))
			{
                
                // Get the address from the pointer to the address
				struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)addrX;
				
                
                // Check if we can get the host from the address
				if (hostPtr) *hostPtr = [self hostFromAddress6:addr6];
                
                // Check if we can get the port from the address
				if (portPtr) *portPtr = [self portFromAddress6:addr6];
				
				return YES;
			}
		}
	}
	
	return NO;
}


/*
    Class method
    Returns carriage return and line feed
    returns NSData
*/
+ (NSData *)CRLFData
{
	return [NSData dataWithBytes:"\x0D\x0A" length:2];
}

/*
    Class method
    Returns a carriage return
    returns NSData
*/
+ (NSData *)CRData
{
	return [NSData dataWithBytes:"\x0D" length:1];
}


/*
    Class method
    Returns line feed data
    returns NSData
*/
+ (NSData *)LFData
{
	return [NSData dataWithBytes:"\x0A" length:1];
}


/*
    Class method
    Returns an empty NSData object
    returns NSData
*/
+ (NSData *)ZeroData
{
    
	return [NSData dataWithBytes:"" length:1];
}

@end	
