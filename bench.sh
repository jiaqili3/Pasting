#!/bin/bash
# Dev benchmark (requires: defaults write com.jiaqili.pasting DevBench -bool YES). Uses the running app.
# Trigger the in-app panel benchmark; results go to ~/Library/Logs/Pasting.log
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.jiaqili.pasting.bench"), object: nil, userInfo: nil, deliverImmediately: true)' 2>/dev/null \
 || osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.jiaqili.pasting.bench", $(), $(), true)'
sleep 2; grep BENCH ~/Library/Logs/Pasting.log | tail -1
