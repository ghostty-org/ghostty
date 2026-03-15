---
name: gh-issue
description: Diagnose a GitHub issue and produce a comprehensive resolution plan (no code changes)
---

# Diagnose GitHub Issue

Takes an issue number or URL and produces a diagnosis and resolution plan.

## Steps

1. Fetch the issue data:
   ```bash
   gh issue view $ARGUMENTS --repo ghostty-org/ghostty --json author,title,number,body,comments
   ```

2. Read the issue title, description, and all comments.

3. Examine the relevant parts of the Ghostty codebase. Analyze the code thoroughly until you have a solid understanding of how it works. Use the architecture guide in CLAUDE.md to navigate efficiently.

4. Explain the issue in detail, including the problem and its root cause.

5. Create a comprehensive plan to solve the issue. The plan should include:
   - Required code changes (with specific file paths and function names)
   - Potential impacts on other parts of the system
   - Necessary tests to be written or updated
   - Performance considerations
   - Security implications
   - Backwards compatibility (if applicable)
   - Link to the source issue

6. Think deeply about edge cases, potential challenges, and the threading model (app thread, IO thread, render thread).

**ONLY CREATE A PLAN. DO NOT WRITE ANY CODE.**
