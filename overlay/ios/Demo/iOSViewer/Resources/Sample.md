---
title: Downright on iOS
status: demo
---
<!-- Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com> -->

# Downright on iOS

This is the **shared engine** from `MarkdownRender`, styling text on *iOS* for the first time. Links like [the plan](https://example.com) should pick up the theme's link colour, and [jump to Math](#math) scrolls within the page.

## Lists and tasks

- A plain bullet
- A bullet with `inline code`
  - A nested bullet
1. First
2. Second

- [x] Phase 1: shared engine builds on iOS
- [ ] Phase 2: a real UIKit reading surface

> A block quote, which on the Mac carries a quote rule.

> [!NOTE]
> A callout. On the Mac this draws an icon and a tinted band.

## Code

```swift
struct Greeting {
    let name: String
    func say() -> String { "Hello, \(name)" } // a comment
}
```

## Image

![The Downright icon](icon.png)

## Diagram

```mermaid
flowchart LR
  A[Source bytes] --> B[Parse]
  B --> C[Decorate]
  C --> D[Draw]
```

## Table

| Part | iOS today |
|---|---|
| MarkdownCore | Builds and tests |
| MarkdownRender engine | Builds and tests |
| Reading view | Not yet |

## Math

Inline math $e^{i\pi} + 1 = 0$ and a display block:

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

---

### Heading 3
#### Heading 4

Footnote reference[^1].

[^1]: The footnote text.
