### 个人自用的脚本存放
#### dockerimages脚本执行流程
1. 提示输入要拉取的Docker镜像名称
2. 在远程服务器(192.168.31.50)上拉取指定镜像
3. 将镜像保存为tar文件
4. 传输tar文件到本地
5. 在本地导入镜像
6. 自动清理临时文件