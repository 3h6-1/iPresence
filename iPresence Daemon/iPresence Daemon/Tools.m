#import "Tools.h"

@implementation Tools
+ (NSDictionary *)parseJSON:(NSString *)json {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}
@end
