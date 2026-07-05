# GitHub PAT 创建指南（用于创建并上传到私有仓库 `winic57/LPA3399Pro-private`）

更新时间：2026-07-05

## 目标

你想把本地项目上传到一个新的 GitHub 私有仓库：

- 目标仓库：`winic57/LPA3399Pro-private`
- 本地目录：`/mnt/sdb3/LPA3399Pro`
- 当前远程是 SSH：`git@github.com:winic57/LPA3399Pro.git`
- 但当前机器的 SSH 对 GitHub 认证失败，所以这次建议使用 **HTTPS + PAT（Personal Access Token）** 完成创建仓库和推送。

> 重要：PAT 就像密码，**不要**发到公开聊天、不要写进代码、不要提交到 Git 仓库。

---

## 推荐方案

优先建议你创建 **Fine-grained personal access token**（细粒度 PAT）。

原因：

- GitHub 官方推荐 fine-grained token，而不是 classic token
- 权限更小，更安全
- 可以限制有效期

但如果你在 fine-grained 页面里发现权限配置太复杂、或因为策略限制无法成功创建，也可以退回到 **Personal access token (classic)**。

---

## 方案 A：创建 Fine-grained PAT（推荐）

### 1）打开 GitHub PAT 设置页

登录 GitHub 后，依次进入：

- 右上角头像
- `Settings`
- 左侧 `Developer settings`
- `Personal access tokens`
- `Fine-grained tokens`
- 点击 `Generate new token`

也可以直接打开（登录后访问）：

- https://github.com/settings/personal-access-tokens/new

---

### 2）填写基本信息

建议这样填：

- **Token name**：`LPA3399Pro-private-upload`
- **Description**：`Create and push private repo for LPA3399Pro`
- **Expiration**：建议先选 `7 days` 或 `30 days`

如果你只打算这一次上传完成就不用了，建议选 **7 days**，更安全。

---

### 3）选择 Resource owner

- **Resource owner**：选择你自己的账号 `winic57`

---

### 4）选择 Repository access

这里建议选：

- **All repositories**

### 为什么不是 “Only select repositories”？

因为你这次要创建的是一个**新的私有仓库** `winic57/LPA3399Pro-private`，仓库现在还不存在。

**我的判断/推断：** 对于“先创建新仓库，再推送”的场景，fine-grained token 通常需要先对该 owner 使用较宽的仓库访问范围；否则新仓库尚未存在，无法在“选定仓库”里提前勾选它。

如果你创建完成仓库后，后续想长期保留这个 token，可以再重新生成一个只限定到该仓库的 token。

---

### 5）设置 Repository permissions

至少建议配置下面这些权限：

#### 必选

- **Administration**: `Read and write`
  - 用于创建仓库、管理仓库级设置
- **Contents**: `Read and write`
  - 用于推送代码内容
- **Metadata**: `Read-only`
  - 一般会自动包含或默认可读，保留即可

#### 建议额外加上

- **Workflows**: `Read and write`

### 为什么建议加 `Workflows` 写权限？

因为你的项目目录里已经存在多个 GitHub Actions 工作流文件，例如：

- `.github/workflows/npu_kernel.yml`
- `.github/workflows/ophub_6.18.y.yml`
- `lpa3399pro-armbian/.github/workflows/...`

如果没有工作流相关权限，后续在通过 API 或某些写入方式处理 `.github/workflows/*` 时可能遇到权限问题。

---

### 6）生成 token

- 检查配置无误后，点击 `Generate token`
- GitHub 只会显示一次完整 token
- **立刻复制并妥善保存**

---

## 建议的本地保存方式（仅本机，勿提交）

### 方式 1：保存到 shell 环境变量（推荐临时使用）

```bash
export GITHUB_PAT='这里替换成你刚复制的token'
```

验证是否设置成功：

```bash
echo "${#GITHUB_PAT}"
```

如果输出是一个大于 20 的数字，通常说明变量里已经有内容。

> 注意：不要把包含真实 token 的命令贴到公开地方。

### 方式 2：保存到仅自己可读的本地文件

```bash
mkdir -p ~/.config/github
printf '%s\n' '这里替换成你刚复制的token' > ~/.config/github/pat_lpa3399pro_private.txt
chmod 600 ~/.config/github/pat_lpa3399pro_private.txt
```

读取时：

```bash
export GITHUB_PAT="$(cat ~/.config/github/pat_lpa3399pro_private.txt)"
```

> 不要把这个文件放进当前项目目录，更不要 `git add`。

---

## 方案 B：创建 Personal access token (classic)（更省事的备选）

如果 fine-grained token 配不通，你可以创建 classic token。

### 1）进入 classic token 页面

登录 GitHub 后进入：

- 右上角头像
- `Settings`
- 左侧 `Developer settings`
- `Personal access tokens`
- `Tokens (classic)`
- `Generate new token`
- `Generate new token (classic)`

也可以直接打开：

- https://github.com/settings/tokens/new

---

### 2）建议填写方式

- **Note**：`LPA3399Pro-private-upload`
- **Expiration**：`7 days` 或 `30 days`

### 3）建议勾选的 scopes

至少勾选：

- `repo`

建议额外勾选：

- `workflow`

### 为什么 classic token 建议勾 `workflow`？

因为你的项目包含 `.github/workflows/*` 文件；GitHub 官方文档在仓库内容写入相关接口中明确说明：

- classic PAT 需要 `repo`
- 修改 `.github/workflows` 还需要 `workflow`

所以为了避免后续推送/写入工作流文件时出问题，建议一起勾上。

---

## 创建好 token 后，如何验证 token 是否可用

在本机终端执行：

```bash
export GITHUB_PAT='这里替换成你的token'
curl -H "Authorization: Bearer $GITHUB_PAT" https://api.github.com/user
```

如果返回中能看到类似下面字段，说明 token 基本可用：

- `login`
- `id`
- `html_url`

如果返回 `401`，通常是 token 不正确、已过期或权限/授权有问题。

---

## 后续我会怎么用这个 token

你把 token 准备好后，我下一步会帮你做这些事：

1. 在本地项目里补一个合适的 `.gitignore`
   - 排除 `logs/`
   - 排除 `build_artifacts/`
   - 也会顺手检查是否需要排除 `artifacts/`、`downloads/`、`*.log` 等
2. 创建新的 GitHub 私有仓库 `winic57/LPA3399Pro-private`
3. 把当前仓库远程从 **SSH** 切换到 **HTTPS**
4. 提交本地变更
5. 推送到新的私有仓库

---

## 为什么这次需要 HTTPS，而不是继续用 SSH

GitHub 官方说明：

- PAT 用于 **HTTPS Git 操作**
- 如果仓库 remote URL 是 SSH，需要切换到 HTTPS 才能直接使用 PAT

你当前机器对 GitHub 的 SSH 认证失败，因此这次最稳妥的路径是：

- 创建 PAT
- 用 HTTPS remote 推送

---

## 给我的最简回复方式

当你创建好 PAT 以后，直接回复我下面任意一种即可：

### 方式 A：只告诉我“已保存到环境变量”

如果你已经在当前 shell 里执行过：

```bash
export GITHUB_PAT='你的token'
```

你就回复我：

- `PAT已设置到环境变量，继续`

### 方式 B：告诉我 token 文件路径

如果你保存到了本地文件，例如：

```bash
~/.config/github/pat_lpa3399pro_private.txt
```

你就回复我：

- `PAT已保存到 ~/.config/github/pat_lpa3399pro_private.txt，继续`

然后我就继续帮你完成：

- `.gitignore` 清理
- 新建私有仓库
- 推送到 `winic57/LPA3399Pro-private`

---

## 官方文档（建议优先看）

1. Managing your personal access tokens  
   https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens

2. Permissions required for fine-grained personal access tokens  
   https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens

3. REST API endpoints for repository contents  
   https://docs.github.com/en/rest/repos/contents

4. Scopes for OAuth apps  
   https://docs.github.com/en/developers/apps/scopes-for-oauth-apps

---

## 我对权限配置的最终建议

### 最推荐：Fine-grained PAT

- Resource owner：`winic57`
- Repository access：`All repositories`
- Permissions:
  - `Administration`: `Read and write`
  - `Contents`: `Read and write`
  - `Metadata`: `Read-only`
  - `Workflows`: `Read and write`
- Expiration：`7 days`

### 省事备选：Classic PAT

- Scopes:
  - `repo`
  - `workflow`
- Expiration：`7 days`

---

## 安全提醒

- 不要把 token 写进 `.md`、`.sh`、`.env` 并提交到仓库
- 不要把 token 发到公开 issue、论坛、群聊
- 用完就删，或者让它尽快过期
- 上传完成后，如果你不再需要它，建议去 GitHub 里直接 `Revoke` 这个 token
