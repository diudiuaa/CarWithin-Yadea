#!/usr/bin/env python3
"""
把 MFI 配件认证身份注入 unsigned IPA，供侧载签名安装。

CarWithin 的本机 CarPlay 需要三个身份文件（位于 .app 根目录）：
    certificate.p7b / leaf.cer / private.x963

源码不包含这些身份；官方 Release 的 IPA 里带有。本脚本把身份目录里的
三个文件注入到「自己编译出的 unsigned IPA」中，之后再用全能签等工具签名安装。

用法:
    python Tools/inject_identity.py <输入.ipa> <身份目录> <输出.ipa>

示例:
    python Tools/inject_identity.py CarWithin-yadea-unsigned.ipa mfi CarWithin-yadea.ipa
"""
import os
import sys
import zipfile

IDENTITY_FILES = ["certificate.p7b", "leaf.cer", "private.x963"]


def find_app_prefix(names):
    """从 zip 文件列表中找 Payload/<xxx>.app/ 前缀。"""
    for name in names:
        if name.startswith("Payload/") and ".app/" in name:
            return name.split(".app/")[0] + ".app"
    for name in names:
        if name.startswith("Payload/") and name.endswith(".app"):
            return name
    return None


def main():
    if len(sys.argv) != 4:
        print("用法: python inject_identity.py <输入.ipa> <身份目录> <输出.ipa>")
        sys.exit(1)

    input_ipa, identity_dir, output_ipa = sys.argv[1], sys.argv[2], sys.argv[3]

    for name in IDENTITY_FILES:
        path = os.path.join(identity_dir, name)
        if not os.path.isfile(path):
            print(f"[错误] 缺少身份文件: {path}")
            sys.exit(1)

    if not os.path.isfile(input_ipa):
        print(f"[错误] 找不到输入 IPA: {input_ipa}")
        sys.exit(1)

    with zipfile.ZipFile(input_ipa, "r") as zin:
        app_prefix = find_app_prefix(zin.namelist())
        if not app_prefix:
            print("[错误] IPA 中未找到 Payload/<xxx>.app")
            sys.exit(1)
        print(f"检测到 App: {app_prefix}")

        with zipfile.ZipFile(output_ipa, "w", zipfile.ZIP_DEFLATED) as zout:
            # 原样复制所有条目，保留压缩方式与权限位
            for item in zin.infolist():
                zout.writestr(item, zin.read(item.filename))

            # 注入身份文件到 .app 根目录
            for name in IDENTITY_FILES:
                arcname = f"{app_prefix}/{name}"
                zout.write(os.path.join(identity_dir, name), arcname)
                print(f"已注入 {arcname}")

    size = os.path.getsize(output_ipa)
    print(f"完成: {output_ipa} ({size} 字节)")
    print("下一步：用全能签等侧载工具对上面的 IPA 签名并安装到 iPhone。")


if __name__ == "__main__":
    main()
