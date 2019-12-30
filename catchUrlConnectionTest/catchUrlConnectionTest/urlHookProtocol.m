//
//  urlHookProtocol.m
//  catchUrlConnectionTest
//
//  Created by runloop on 2019/12/30.
//  Copyright © 2019 slw. All rights reserved.
//

#import "urlHookProtocol.h"
@interface urlHookProtocol ()
@property (nonatomic, strong) NSURLConnection *connection;

@end

@implementation urlHookProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    
    BPWebDebugEvnConfig *config = [BPWebDebugEvnConfig shareInstance];
    if(![config isFromWebView:request])//只处理来自webview的请求
    {
        BP_TRACE("debugURLProtocol:%s NotFromWebView return NO",[request.URL.absoluteString UTF8String]);
        return NO;
    }
    //无论是否开启测试环境模式，对代理服务器域名的请求进行转发，不然用户无法访问代理配置页面。
    if ([config isProxyDomian:request.URL.host]) {
        BP_TRACE("debugURLProtocol:%s isProxyDomian return YES",[request.URL.absoluteString UTF8String]);
        return YES;
    }
    if ([config isDebugModeOn] && [NSURLProtocol propertyForKey:kProxyTag inRequest:request] == nil) {
        NSString *proxyID = [config proxyIDForURL:request.URL.absoluteString];
        if (proxyID != nil) {
            BP_TRACE("debugURLProtocol:%s proxyID return YES",[request.URL.absoluteString UTF8String]);
            return YES;
        }
    }
    
    BP_TRACE("debugURLProtocol:%s return NO",[request.URL.absoluteString UTF8String]);
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    BPWebDebugEvnConfig *config = [BPWebDebugEvnConfig shareInstance];
    NSString *proxyID = [config proxyIDForURL:self.request.URL.absoluteString];
    BP_TRACE("startLoading:%s,URL:%s",[proxyID UTF8String],[self.request.URL.absoluteString UTF8String]);
    if (proxyID != nil) {
        NSMutableURLRequest *newRequest = [self.request mutableCopy];
        if ([proxyID isEqualToString:DEFAULTPROXYID]) {
            //不走代理，走url替换
            NSString *newURL = [config replacedURLForURL:self.request.URL.absoluteString];
            if (newURL) {
                [newRequest setURL:[NSURL URLWithString:newURL]];
                NSDictionary *cookieHeaders = [self cookiesForRequest:self.request];
                [newRequest setValue: [cookieHeaders objectForKey: @"Cookie" ]forHTTPHeaderField:@"Cookie"];
            }else
            {
                BP_ERROR("replace URL is nil");
                return;
            }
        }else
        {
            NSURL *newURL = [self newURLForURL:self.request.URL];
            NSDictionary *cookieHeaders = [self cookiesForRequest:self.request ];//withProxyURL:newURL];
            [newRequest setURL:newURL];
            NSInteger timestamp = (NSInteger)[[NSDate date]timeIntervalSince1970];
            NSString *md5value = [self MD5WithCookies:[cookieHeaders objectForKey: @"Cookie" ] proxyID:proxyID timestamp:timestamp req:newRequest];
            NSString *uin = [[serviceFactoryInstance() getAccountService] getUinStr];
            NSString *value = [NSString stringWithFormat:@"%@,%@,%d,%@,%@",proxyID,[UIDevice deviceIdentifier],timestamp,uin,md5value];
            [newRequest setValue:value forHTTPHeaderField:kExtensionHeader];
            [newRequest setValue: [cookieHeaders objectForKey: @"Cookie" ]forHTTPHeaderField:@"Cookie"];
        }
        
        [NSURLProtocol setProperty:@YES forKey:kProxyTag inRequest:newRequest];
        newRequest.cachePolicy = NSURLRequestReloadIgnoringCacheData;
        self.connection = [NSURLConnection connectionWithRequest:newRequest delegate:self];
    }
}

- (void)stopLoading {
    [self.connection cancel];
    self.connection = nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    NSString * refererUrl =   connection.originalRequest.allHTTPHeaderFields[@"Referer"];
    NSString *  finalUrlStr= [[BPWebDebugMainRequestCache shareInstance]finalURLStr];
    BOOL isShowTips = [[BPWebDebugMainRequestCache shareInstance]isShowTips];
    
    BPWebViewController * webViewController =[[BPWebDebugMainRequestCache shareInstance] currentWebviewController];
    
    BOOL isNeedIgnore =[self isNeedIgnoreWithURL:finalUrlStr];
    //如果不忽略的域名内，则进行检测
    if (isNeedIgnore ==NO)
    {
        // 替换URL走这里
        BPWebDebugEvnConfig *config = [BPWebDebugEvnConfig shareInstance];
        NSString *proxyID = [config proxyIDForURL:finalUrlStr];
        if (proxyID != nil && isShowTips ==NO)
        {
            [self showTipsOnViewController:webViewController];
        }
        
        //代理走这里
        BOOL isEqual  =  [self isFromSource:finalUrlStr subRequestReferer:refererUrl];
        //原请求url和referer相同，webviewcontroller，finalUrlStr不为空，isShowTips没提示过
        if (isEqual == YES &&  webViewController!=nil  && finalUrlStr!=nil &&  isShowTips ==NO)
        {
            [self showTipsOnViewController:webViewController];
        }
    }
    
    
    [self.client URLProtocol:self didLoadData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    [self.client URLProtocol:self didFailWithError:error];
    self.connection = nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:[(NSHTTPURLResponse*)response allHeaderFields] forURL:response.URL];
    NSArray *newCookies = [self cookies:cookies ToDomain:self.request.URL.host];
    [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookies:newCookies forURL:self.request.URL mainDocumentURL:nil];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];//不缓存
}


- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    [self.client URLProtocolDidFinishLoading:self];
    self.connection = nil;
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                  willCacheResponse:(NSCachedURLResponse *)cachedResponse
{
    return nil;
}

//302重定向
- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)redirectResponse
{
    if ([redirectResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpRes = (NSHTTPURLResponse *)redirectResponse;
        if ([httpRes statusCode] == 302) {
            NSMutableURLRequest *req = [request copy];
            [NSURLProtocol removePropertyForKey:kProxyTag inRequest:req];
            request = [req copy];
            [self.client URLProtocol:self wasRedirectedToRequest:request redirectResponse:redirectResponse];
        }
    }
    return request;
}
