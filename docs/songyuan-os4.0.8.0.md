# songyuan OS4.0.8.0 SukiSU 构建

`kernel-songyuan-61269.yml` 仅构建 SukiSU-Nova，固定以下设备内核标识：

- kernel/common: `0a1dc0413ec7f42ad5924505ca2a519900ccf770`
- 内核发布串: `6.12.69-android16-6-g0a1dc0413ec7-ab16271006-4k`
- 构建时间: `Sat Sep  5 12:19:39 UTC 2026`

保留原厂 ZRAM 与 zsmalloc 模块；专用工作流不再提供额外压缩算法开关。
NoMount 默认开启。网络增强保留 IPSet、BBR 和 Qdisc，关闭会把 netfs 提升为
内建的 CIFS，继续让原厂 system_dlkm 加载 netfs.ko。打包前读取最终 Image 的
内嵌配置，检查 netfs、ZRAM、zsmalloc 保持模块，以及请求的 NoMount 已启用。

6.12 内核会为已集成的 BBG 与仍调用 `security_add_hooks()`
的内建 SukiSU-Nova 分别预留注册容量。容量不足时仍由内核的原有检查处理。

## 为什么不部署通用 ZRAM 模块

用户提供的完整 OTA 为
`songyuan-ota_full-OS4.0.8.0.XGNCNXM-user-17.0-14c50f1898.zip`，
SHA-256 为 `e2e997c2ce8564eaae97952fb7864f76d9f67efc0b5cbb2daa8fc16400086b5b`。
boot、vendor_boot、vendor_dlkm、system_dlkm 均已按 payload 分区清单校验。

静态 ELF 分析发现：

- vendor_dlkm 的原厂 zram 依赖 `zsmalloc,qpace_drv`。
- 原厂 node_cache 和 vendor zram 要求 `zs_malloc` CRC `0x1804f5bc`。
- 同一固件的通用 system zram/zsmalloc 使用 `zs_malloc` CRC `0x36f39fe1`。
- 单独刷入 Image 不会更新额外算法所在的 zram.ko；直接替换通用模块也无法
  满足上述厂商模块依赖。

因此本次按用户选择保留原厂模块。不要通过关闭 MODVERSIONS、伪造 CRC，或
使用晚期模块挂载来宣称已完成早启动模块替换。额外算法需要先移植并验证厂商
模块接口与加载流程，不能仅凭版本串相同推断兼容。

以上是离线分区与符号分析，不代表新编译的 SukiSU 内核已通过实机启动验证。
