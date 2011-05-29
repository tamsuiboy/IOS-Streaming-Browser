#import <Foundation/Foundation.h>
#import "HTTPResponse.h"


// Implements HTTPResponse protocol
@interface HTTPRedirectResponse : NSObject <HTTPResponse>
{
	NSString *redirectPath;
}


/*
    Initialize the HTTPRedirectResponse with a redirectPath
    param NSString
    returns id
*/
- (id)initWithPath:(NSString *)redirectPath;

@end
