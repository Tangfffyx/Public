#作者@chouchoui

hostname = testflight.apple.com

^https:\/\/testflight\.apple\.com\/v3\/accounts/.*\/apps$ url script-request-header https://raw.githubusercontent.com/chouchoui/QuanX/master/Scripts/testflight/TF_keys.js

^https://testflight.apple.com/join/(.*) url script-request-header https://raw.githubusercontent.com/chouchoui/QuanX/master/Scripts/testflight/TF_keys.js


/**************************
使用方法：
1、手动添加 cron 任务
[task_local]
*/10 * * * * * https://raw.githubusercontent.com/Tangfffyx/Public/main/Script/tf_auto_join.js, tag=TestFlight自动加入, img-url= https://raw.githubusercontent.com/Orz-3/mini/master/Color/testflight.png, enabled=true

2、需关闭TF多账户管理重写，并打开TestFlight一次，qx会提示信息获取成功

3、打开此重写

4、复制想加入的链接（例如https://testflight.apple.com/join/fl3VSxsx）
粘贴到浏览器打开，以获取 APP_ID

5、获取 APP_ID 成功后，打开 cron 任务

最后：
   如何清除 APP_ID 持久化数据：
      在 boxjs “我的”，点击“数据查看器”，“数据值”输入APP_ID
      点击 view 查看，把内容清空后保存。
**************************/
