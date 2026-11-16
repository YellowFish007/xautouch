/**
 * main.m - XAutouch Explorer 程序入口
 *
 * 独立 Theos application target。界面不使用 storyboard，全部由代码构建；
 * 应用只通过本地 HTTP API 操作文件，不直接读写越狱根文件系统。
 */
#import <UIKit/UIKit.h>
#import "XTEAppDelegate.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([XTEAppDelegate class]));
    }
}
