# spec —— 语言无关的契约

`TransCore` 与客户端不各自手抄提示词，共享这里的数据与规则。

| 文件 | 内容 |
| --- | --- |
| `prompts/prompts.json` | 翻译与润色的提示词、语言名映射、编号行格式 |
| `providers.presets.json` | 提供商预设 |
| `parsing.json` | 分块正则、引号剥离、重试与并发默认值、思考模式规则 |
| `settings.schema.json` | 翻译设置结构 |
| `providers.schema.json` | 提供商存储结构 |
| `job.schema.json` | 任务与结果模型 |

## 修改流程

1. 改 `spec/*.json`；
2. 重新生成常量：

   ```sh
   python3 tools/gen_spec.py
   ```

3. 提交 spec 与生成物 `Sources/TransCore/Generated/Spec.swift`；
4. 校验生成物是否最新：

   ```sh
   python3 tools/gen_spec.py --check
   ```

## 为什么生成而不是运行时读取

- 运行时读文件需要处理打包、资源路径、缺失兜底；
- 生成物可被编译期检查，提示词写错会直接编译失败或测试失败；
- 生成物进仓库后，review 时能看到提示词的每一次改动。

## 与 fixtures 的关系

`spec/` 描述**规则**，`fixtures/` 描述**行为**。
规则改了但 fixtures 没变，说明行为可能被意外改动；测试会暴露这一点。
