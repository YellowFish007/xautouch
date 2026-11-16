#import "XTLogger.h"

void XTLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [[XTLogger sharedInstance] log:msg];
}

@implementation XTLogger {
    NSMutableArray<NSString *> *_lines;
    NSLock *_lock;
}

+ (instancetype)sharedInstance {
    static XTLogger *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lines = [NSMutableArray arrayWithCapacity:500];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)log:(NSString *)line {
    NSString *stamped = [NSString stringWithFormat:@"[%@] %@",
                         [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                       dateStyle:NSDateFormatterNoStyle
                                                       timeStyle:NSDateFormatterMediumStyle], line];
    [_lock lock];
    [_lines addObject:stamped];
    if (_lines.count > 500) [_lines removeObjectsInRange:NSMakeRange(0, _lines.count - 500)];
    [_lock unlock];
    NSLog(@"%@", stamped);
}

- (NSArray<NSString *> *)recentLines:(NSUInteger)limit {
    [_lock lock];
    NSUInteger n = MIN(limit, _lines.count);
    NSArray *r = [_lines subarrayWithRange:NSMakeRange(_lines.count - n, n)];
    [_lock unlock];
    return r;
}
@end
