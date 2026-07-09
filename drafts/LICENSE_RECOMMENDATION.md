# LICENSE 选型备忘

> 等用户拍板。3 个候选 + 我的推荐。

## 候选

### MIT（推荐）
- **优势**：最宽松、最常见、shell 脚本类项目事实标准（如 [oh-my-zsh](https://github.com/ohmyzsh/ohmyzsh)、[rbenv](https://github.com/rbenv/rbenv)）
- **劣势**：不提供专利授权（虽然 bash 脚本几乎不涉及专利）
- **长度**：~170 字
- **适合**：工具类、个人项目、希望最大化传播

### Apache-2.0
- **优势**：含专利授权（grant + retaliation clause），企业友好；明确贡献者商标条款
- **劣势**：比 MIT 长（~400 字），部分个人开发者觉得"太正式"
- **长度**：~400 字
- **适合**：企业主导项目、涉及专利顾虑的领域（AI/ML 较多见）

### 保留所有权利（现状）
- **优势**：什么都不用做
- **劣势**：他人**不能合法** fork / 修改 / 再分发；repo 价值大降；GitHub 搜索结果也容易被忽略（"无 license" 是 warning）
- **适合**：纯个人使用、不打算公开

## 我的推荐

**MIT**。

理由：
1. **本项目是工具，不是产品**——所有价值在脚本代码本身，不在品牌/专利
2. **目标受众是开发者**——他们最熟悉的 license 是 MIT，秒接受
3. **shell 脚本类项目的肌肉记忆**——oh-my-zsh、rbenv、nvm、fzf 全是 MIT
4. **本项目没有 AI/ML 专利敏感问题**——纯 bash + curl + jq，没有可专利化算法
5. **Apache-2.0 的专利条款在本场景没价值**——没人在乎 1 个 240 行 bash 脚本会不会被告专利侵权

如果将来想"商业化"（如做 SaaS wrapper），MIT 也完全 OK——MIT 允许闭源二次分发，不影响商业用途。

## 怎么加

```bash
# 选 MIT 后：
curl -o LICENSE https://raw.githubusercontent.com/licenses/license-templates/master/templates/mit.txt
# 或自己手写 17 行（[opensource.org/licenses/MIT](https://opensource.org/licenses/MIT) 标准模板）

# commit：
git add LICENSE
git commit -m "Add MIT license"
git push
```

## 我的建议执行方式

用户拍板后，我可以：
1. 写 LICENSE 文件（MIT / Apache-2.0 任选）
2. README "许可" 段从"未声明 License" 改成"MIT License — 详见 [LICENSE](./LICENSE)"
3. commit + push 到 cstdr/minimax-claude-statusline
4. （MIT 的话）顺便在 repo 描述里加 `MIT-licensed` 之类关键词

等用户说"加 LICENSE"或"加 MIT"再动作。

## 公开与否

**注意**：本备忘不影响 visibility 决策。仓库可以保持 private 同时有 LICENSE；private repo 的 LICENSE 只对"被授予访问权的人"有效。GitHub 公开 LICENSE 字段是另一回事。

也就是说：可以选 MIT + 保持 private，等你说"公开"再翻 public。
