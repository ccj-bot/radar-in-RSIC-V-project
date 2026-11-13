# GitHub 关联和同步

本项目已配置：

```text
origin = https://github.com/ccj-bot/radarbrain-riscv-sar.git
branch = main
user.name = ccj-bot
user.email = 230313591+ccj-bot@users.noreply.github.com
```

作者信息仅在当前仓库生效。Git 提交署名和 GitHub 登录认证是两回事；推送使用这台电脑的 Git 凭据管理器。

查看关联：

```powershell
cd 'D:\profile\radar in RSIC-V'
git remote -v
git status
```

日常同步：先在工作区干净时 `git pull --ff-only`，然后修改代码。提交时明确选择修改的文件，例如：

```powershell
git add -- README.md docs src hardware .gitignore .gitattributes AGENTS.md
git diff --cached --stat
git diff --cached --name-only
git commit -m "Describe the change"
git push
```

首次推送使用 `git push -u origin main`，之后普通 `git push` 即可。

**权重不上传。** 当前忽略规则覆盖模型目录及 PT、ONNX、checkpoint、safetensors 等格式。不要使用 `git add -f`，不要通过 LFS、归档或改名绕过规则。每次提交仍需检查实际暂存内容，尤其是新增格式或二进制文件。

新电脑获取代码：

```powershell
git clone https://github.com/ccj-bot/radarbrain-riscv-sar.git
```

克隆不包含模型、采集数据、运行库及历史材料，这些资产需要另外在本地配置。不要强制推送来解决远程分支冲突。
