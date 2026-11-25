# 更新记录

这里记录 `supernene/vio` 仓库中可从 Git 历史核实的版本变化。脚本的安装和升级入口一直是 `main/vless-server.sh`。

## v3.5.7 · 2026-11-25

- Xray 直接从每个节点生成入站，兼容单对象、数组和单元素数组；保留原有端口标签。VMess、Trojan、VLESS 和 SOCKS 的账号按节点读取，WS 的 Host 和回落目标也按节点读取。使用回落时拒绝重复的 WS 路径，避免覆盖已有节点。
- Xray 保留显式后端监听地址和端口。增删和覆盖时先用 `xray run -test` 校验临时配置，应用失败时恢复原配置及节点数据。只有明确删除最后一个 Xray 节点才停用服务。
- 增加 Xray 多节点、回落和应用失败的回归测试。

## v3.5.6 · 2026-11-25

- [修复 Sing-box 多节点](https://github.com/supernene/vio/commit/1e199812101d5b37a3e7f38bef45e4058b2fb67a)：AnyTLS、Hysteria2、TUIC 逐节点生成入站，兼容单对象及数组；独立保留用户、公布端口和监听端口。
- 按节点删除；配置先通过 `sing-box check` 再替换，失败时回滚。管理脚本可检测并修复旧配置遗漏的节点。

## v3.5.5 · 2026-11-22 与 2026-11-07

- 2026-11-22，[固定 ACME 证书机构](https://github.com/supernene/vio/commit/01206842cad849ec77ec361fb3ca272472fd981d)：注册、HTTP 和 DNS 申请及手动 DNS 续期显式使用 Let's Encrypt，避免跟随 acme.sh 默认的 ZeroSSL。版本号在这次提交里保持不变。
- 2026-11-07，[修复 Sing-box 访问限制](https://github.com/supernene/vio/commit/4c9aae1b94fbafb13cc8eaa600ba9373dd49c584)：修复限制规则的生成和优先级，维护本地规则集，更新失败时保留旧配置，并补上回归测试。

## v3.5.4 · 2026-11-07

- [修复 AnyTLS 证书管理](https://github.com/supernene/vio/commit/3e3a992f2bb82aee6460bfd693fe0536823a2b9f)：检查域名、有效期、信任链和私钥；先暂存并校验新证书，再切换证书路径，重启失败时恢复旧证书。
- 正式证书和自签证书分开处理，分享链接按实际证书设置校验选项，新增证书回归测试。

## v3.5.3 · 2026-07-20

- [首次上传非空服务端脚本](https://github.com/supernene/vio/commit/895efd1)，是这个仓库中最早可核实的脚本版本。此前只有一次空文件上传及删除，无法从仓库追溯更早版本的改动。
