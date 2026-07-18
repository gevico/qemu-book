# PDF 输出目录

运行 `make pdf` 或 `make pdf-native` 后，完整书稿会生成到此目录：

```text
深入理解-QEMU-设计原理.pdf
```

PDF 是构建产物，不提交到 Git。GitHub Actions 会把普通构建保存为 workflow artifact；`v*` Tag 构建会发布到同名 GitHub Release，并在文件名中加入 Tag。
