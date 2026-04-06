# **I Claimed My Claude Code Hook Saves 10-20x Tokens. I Ran 228 Tests. Here’s Why I’m Scrapping It.**

*How a rigorous benchmark destroyed my own marketing claims \- and what I learned about building honest developer tools.*

---

***TL;DR:** I built a Claude Code hook claiming 10-20x token savings on file reads. After 228 benchmark sessions, the real number was 0% median improvement — 12 losses, 3 wins. I found two benchmark bugs that invalidated the strongest results, and discovered that a one-line CLAUDE.md instruction replaces 236 lines of hook infrastructure for the only format it genuinely helped. I scrapped the project.*  
---

I recently shipped a Claude Code hook called [claude-code-md-hook](https://github.com/sunlesshalo/claude-code-md-hook). It intercepts file reads, converts binary documents (PDF, DOCX, XLSX, PPTX, HTML) to markdown using Microsoft’s markitdown, and for large files, returns a structural index instead of the full content \- forcing Claude to make targeted section reads.

The README claimed **“10-20x token savings.”**

The community wanted numbers. So I built a benchmark to prove my claims. The benchmark proved something else entirely.

## **The Benchmark Design**

I wanted this to be rigorous enough that the results would be unchallengeable. Here’s what I built:

* **7 file types**: PDF (text-heavy), PDF (mixed layout), DOCX, XLSX, PPTX, HTML, and native Markdown  
* **3 size classes**: S1 (small), S2 (medium, \~150-300 lines post-conversion), S3 (large, 500+ lines \- triggering the indexing feature)  
* **19 test cells** (not all types had all sizes \- markdown only had S3)  
* **2 conditions**: hook ON vs. hook OFF (native Claude reads)  
* **3 runs per cell**, median reported (to account for Claude’s inherent variability)  
* **10 factual questions per file** with embedded answer keys, scored 0-20

Each question had a known correct answer baked into the generated test files. No ambiguity. No subjective grading. 

Total: **114 benchmark sessions per version. 228 sessions across v1 and v2.**

Model: Claude Haiku 4.5 (cheaper per-run, still measures the token dynamics that matter).

## 

## **V1 Results: The Claim Is Dead**

Here are the headline numbers from the first 114 runs:

Median token savings:  0%  
Wins: 3 out of 19 cells  
Losses: 12 out of 19 cells  
Neutral: 4 out of 19 cells

**The “10-20x savings” claim was dead.** Across 19 test cells, only 3 showed any improvement. Twelve were actively worse.

### **Where the hook won (v1)**

| File | Size | Native Tokens | Hook Tokens | Savings |
| :---- | :---- | :---- | :---- | :---- |
| pptx | S3 (55 slides) | 1,330,060 | 194,280 | **85.4%** |
| xlsx | S2 (180 rows) | 595,746 | 257,831 | **56.7%** |
| docx | S3 | 517,749 | 386,834 | **25.3%** |

###  **Where the hook was catastrophically worse (v1)**

![][image1]   
The markdown result was particularly humbling: the hook made Claude *worse* at reading its own native format. A **154% increase** in tokens for identical quality.

For PDF-text and HTML? The hook did nothing across 9 test cells \- 1.0x ratio, zero quality change. Pure overhead.

## **The Turn Inflation Discovery**

The data revealed something I hadn’t anticipated. The hook’s indexing feature \- the one I was excited about \- was the primary source of token waste.

Here’s how it works: when a converted file exceeds 300 lines, the hook *denies* the read and returns a structural index (heading → line number mapping). Claude then makes targeted reads with offset and limit parameters.

Sounds efficient in theory. In practice, it created **turn inflation spirals**.

Each time Claude makes a new tool call, the entire conversation history is re-read as cached tokens. A file that Claude reads natively in 2 turns (one read, one answer) might take 14-23 turns through the hook’s index-and-fetch cycle. Every extra turn re-accumulates the full context.

![][image2] 

Here’s what that looks like in practice. A native read is 2 turns: read file, answer question. The hook’s index-and-fetch cycle balloons that to 14+ turns, and every turn re-reads everything before it:

![][image3] 

For PDF-mixed files, the index was especially useless. markitdown’s PDF conversion produces headingless text, so the index returned: *“(No markdown headings found \- navigate by line number).”* Claude got denied, received a useless index, and had to blindly guess offset ranges across dozens of turns.

The indexing threshold was also too aggressive. A 3-page PDF converted to 481 lines of markdown \- just barely over the 300-line threshold \- triggering the full deny-and-index cycle on what should have been a trivial read.

## **Under the Hood: What the Read Tool Already Does**

Before deciding what to fix, I needed to understand what Claude Code’s Read tool does natively. Looking at the benchmark outputs and Claude Code's documented behavior (v2.1.89), I found something that reframed the entire project.

### **PDF: Already Handled Natively**

Claude Code routes PDFs through dedicated handling. The raw PDF bytes are base64-encoded and sent to the Anthropic API as a native document content block  \-  no conversion needed. (For models older than Sonnet 3.5 v2, native PDF reading isn't supported at all; Claude Code throws an error and requires using the pages parameter with poppler-utils for page-by-page extraction at 100 DPI.) 

Either way: Claude Code already has a complete PDF pipeline. My hook added a markitdown conversion step in front of something that already worked perfectly. The benchmark confirmed this  \-  six PDF test cells, zero improvement:

| PDF Type | S1 | S2 | S3 |
| :---- | :---- | :---- | :---- |
| pdf-text | 0.0% | 0.0% | 0.0% |
| pdf-mixed | 0.0% | 0.0% | 0.0% |

###  **HTML: Already Handled Natively**

HTML files aren’t in Claude Code’s binary rejection list. The Read tool passes them through as plain text \- raw tags and all. Claude parses the structure itself. Three test cells, zero improvement.

### **DOCX, XLSX, PPTX: Rejected as Binary**

This is where it gets interesting. Claude Code’s Read tool maintains a blocklist of binary extensions \- .docx, .xlsx, .pptx all get rejected with: *“This tool cannot read binary files.”*

But Claude doesn’t always give up. For **DOCX**, it pivots to Bash \- running textutil \-convert txt or extracting XML via unzip. This worked: DOCX S1 scored 16/20 natively, S3 scored 20/20. For **XLSX**, similar Bash workarounds with mediocre results (8-10/20). For **PPTX**, Claude gives up entirely \- more on that in a moment.

This meant the hook was redundant for **10 out of 19 test cells** (all PDFs, all HTMLs, markdown) and merely a convenience for DOCX and XLSX (replacing multi-turn Bash fumbling with a clean markdown pass-through).

## **The Three-Agent Debate**

I spawned three AI agents with the complete v1 data and distinct perspectives:

| Agent | Verdict | Key Argument |
| :---- | :---- | :---- |
| **Minimalist Pragmatist** | Gut it | *“Kill the entire indexing/deny mechanism. It is responsible for every case where the hook performs worse than native.”* |
| **Ambitious Product Thinker** | Evolve it | *“This is the embryo of a document intelligence layer for Claude Code.”* |
| **Data-Driven Engineer** | Fix it surgically | Per-type thresholds \+ index quality gate. PPTX: always index. DOCX: index at 500+ lines. XLSX: never index. |

All three agreed on the core: **drop PDF, HTML, and markdown.** The disagreement was only on how much to invest in the remaining formats.

## **V2: The Surgical Rebuild**

I implemented the consensus:

\# v2: Per-type conversion config with individual index thresholds  
CONVERT\_CONFIG \= {  
    '.pptx': {'index\_threshold': 0},       \# Always index (slide structure)  
    '.docx': {'index\_threshold': 500},      \# Index large docs only  
    '.xlsx': {'index\_threshold': 999999},   \# Never index (tables don't benefit)  
}  
MIN\_INDEX\_ENTRIES \= 3  \# Don't deny if index has fewer than 3 headings

Four changes, no new features. Just following the data.

### **V2 Results**

The improvements were dramatic:

![][image4] 

For dropped types (PDF, HTML, markdown), the hook now exits immediately: 1.0x ratio, zero overhead. Clean.

For the kept types, v2 looked genuinely good:

| File Type | Size | Native Tokens | Hook Tokens | Ratio | Savings |
| :---- | :---- | :---- | :---- | :---- | :---- |
| pptx | S3 | 1,330,060 | 194,317 | **6.8x** | **85.4%** |
| pptx | S2 | 872,298 | 191,744 | **4.5x** | **78.0%** |
| xlsx | S2 | 595,746 | 258,756 | **2.3x** | **56.6%** |
| docx | S2 | 341,841 | 191,716 | **1.8x** | **43.9%** |
| docx | S3 | 517,749 | 320,907 | **1.6x** | **38.0%** |

The DOCX S2 result was the crown jewel: native Claude scored **0/20** while the hook scored **20/20**. Not just token savings \- the hook appeared to *rescue* document comprehension entirely.

## **The Plot Twist: Questioning the Data**

Then I asked a dangerous question: *“Are we sure the quality rescue is real? Are we sure Claude can’t handle these file types natively?”*

I went back to the raw JSON outputs \- the actual Claude responses during benchmark runs \- and found two things that killed the project.

### **Discovery 1: PPTX \- It’s Not Hook vs. Native. It’s Hook vs. Nothing.**

When Claude tried to read a .pptx file natively, here’s what it said:

“I don’t have a tool that can directly read PowerPoint (.pptx) files. The Read tool I have access to works with PDFs, images, text files, and Jupyter notebooks, but not the binary PPTX format.”

It didn’t even try. It refused outright and asked the user to convert the file manually. Unlike DOCX (where Claude pivots to textutil or unzip) and XLSX (where it attempts Bash extraction), for PPTX Claude has no workaround at all.

The “native” benchmark runs were just Claude burning tokens spiraling through 13-24 turns of confusion about how to open the file. The token counts from those runs weren’t measuring native reading \- they were measuring refusal behavior.

The hook’s 6.8x “savings” for PPTX S3? It’s not 6.8x more efficient than native reading. Native reading doesn’t exist for this format. The comparison is meaningless.

### **Discovery 2: DOCX \- The Quality Rescue Was a Benchmark Bug**

The DOCX S2 result \- 0/20 native vs. 20/20 hook, the \+20 quality delta that was supposed to justify the project \- was a lie.

In the raw output for docx\_S2\_OFF\_run2, Claude says:

“I’ve read the S2.pdf file, but it contains Meridian Holdings Corp’s Annual Financial Report for FY2025, not a service agreement.”

Claude read the **wrong file**. It opened files/pdf-text/S2.pdf instead of files/docx/S2.docx. Why? Because the Read tool rejects .docx as binary, so Claude falls back to Bash workarounds. During that multi-turn fumbling \- listing directories, trying textutil, exploring the file tree \- it stumbled into a sibling directory where a different S2 file lived. The test files were organized by type (files/docx/S2.docx, files/pdf-text/S2.pdf), and Claude navigated to the wrong one.

Run 3 did the same thing. Run 1 read the correct file and scored 20/20.

So the median native score for DOCX S2 was 0/20 \- but only because 2 out of 3 runs read the wrong file entirely. When Claude actually read the DOCX, it handled it fine.

For DOCX S3, the same pattern: run 1 read “the OpenPipeline Framework Contributor Guide” (a completely unrelated document from a different project), scoring 0/20. Runs 2 and 3 read the correct file and scored 20/20.

The “quality rescue” wasn’t the hook making DOCX readable. It was the hook preventing file misrouting by converting the DOCX to markdown in a predictable cache location. A real capability, but not the one I claimed.

## **The Kill Decision**

I spawned another three-agent debate: kill, save, or pivot?

**The Devil’s Advocate** was merciless:

“The hook is really a large PPTX converter dressed up as a general-purpose tool. A one-line system prompt instruction achieves 90% of the value at 0% of the complexity.”

The complexity tax for the hook in production: \- 236 lines of bash \+ Python \- 14 copies across my agent fleet \- markitdown dependency with auto-install logic \- .cache/ directory management per project \- .noconvert toggle mechanism \- Per-type threshold tuning

All of this to serve a few test conditions, two of which involved quality degradation.

**The Project Champion** tried to save it by reframing it as “Office Document Rescue for Claude Code,” but even they admitted the original “10-20x” claim “needs to die.”

**The Content Strategist** saw the real asset:

“Regardless of whether the hook ships, the 228-run benchmark is the real asset. Most open-source tool authors never go back and test their claims. The implicit comparison writes itself.”

The final decision was straightforward. For the only real capability gap \- PPTX, where Claude genuinely cannot read the format \- you don’t need a 236-line hook. You need one line in your project’s CLAUDE.md:

**The one-line fix that replaces the entire project:**

When you need to read .pptx files, first convert them using: markitdown \<file\_path\>

*Prerequisite: pipx install markitdown (one-time setup)*

Same result. No hook infrastructure. No 14 copies to maintain. No cache management. No threshold tuning.

I’m scrapping the project.

## **What I Learned (And What You Should Steal)**

### **1\. Measure before you market**

The “10-20x” claim came from back-of-envelope reasoning: binary file → markdown conversion must be smaller, and indexing must prevent full reads. Both assumptions were wrong for most file types. Claude already reads PDFs natively through the API’s built-in document support. And “preventing full reads” via indexing triggers turn inflation that costs more tokens than the full read would have.

**If you’re building a Claude Code hook that claims performance improvements, run an A/B benchmark before writing the README.**

### **2\. Token savings ≠ turn count × file size**

The naive mental model is: “smaller file \= fewer tokens.” The actual equation includes conversation context re-accumulation across turns. A hook that forces Claude into 23 turns of targeted reads can easily cost 13x more than letting it read the whole file in 2 turns, because each turn re-reads the entire conversation history as cached tokens.

**Measure total session tokens, not just file tokens.**

### **3\. Your benchmark can lie to you**

My benchmark had a bug I didn’t catch until I read the raw outputs. The DOCX “quality rescue” (0/20 native → 20/20 hook) was Claude reading the wrong file in OFF-condition runs. The PPTX “savings” were being compared against Claude’s refusal to read the format at all.

**Always inspect the raw outputs. Aggregate scores hide failure modes.**

### **4\. The complexity tax is real**

A 236-line bash/Python hook with auto-install logic, caching, per-type thresholds, a quality gate, and 14 deployed copies has ongoing maintenance cost. Every Claude Code update could break the hook API. Every markitdown update could change output format. Every new file type needs threshold tuning.

If a system prompt instruction gets you 90% of the result, the hook isn’t worth maintaining.

### **5\. Know what the platform already does**

Half my hook was solving problems that didn’t exist. Claude Code already sends PDFs to the API as native document blocks. It handles raw HTML just fine. I built conversion pipelines for formats that already worked \- because I assumed instead of checking.

**Before building a tool that wraps platform behavior, understand what the platform already handles.**

## ---

**The Raw Data**

The complete benchmark data \- all 228 sessions, raw JSON outputs, scoring sheets, and both versions of the hook \- is available on request.

![][image5] V2 Final Verdict

Here’s the full v2 results table:

| File Type | Size | Native Tokens | Hook Tokens | Ratio | Savings | Quality (N) | Quality (H) | Delta |
| :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- |
| docx | S1 | 319,385 | 319,311 | 1.0x | 0.0% | 16/20 | 14/20 | \-2 |
| **docx** | **S2** | **341,841** | **191,716** | **1.8x** | **43.9%** | **0/20 \!\!\!** | **20/20** | **\+20 \!\!\!** |
| **docx** | **S3** | **517,749** | **320,907** | **1.6x** | **38.0%** | 20/20 | 20/20 | 0 |
| html | S1 | 127,566 | 127,552 | 1.0x | 0.0% | 18/20 | 18/20 | 0 |
| html | S2 | 128,655 | 128,677 | 1.0x | \-0.0% | 18/20 | 18/20 | 0 |
| html | S3 | 137,303 | 137,310 | 1.0x | \-0.0% | 18/20 | 18/20 | 0 |
| markdown | S3 | 130,530 | 130,530 | 1.0x | 0.0% | 20/20 | 20/20 | 0 |
| pdf-mixed | S1 | 132,177 | 132,192 | 1.0x | \-0.0% | 17/20 | 17/20 | 0 |
| pdf-mixed | S2 | 152,443 | 152,408 | 1.0x | 0.0% | 17/20 | 17/20 | 0 |
| pdf-mixed | S3 | 226,974 | 226,985 | 1.0x | \-0.0% | 17/20 | 17/20 | 0 |
| pdf-text | S1 | 131,815 | 131,858 | 1.0x | \-0.0% | 20/20 | 20/20 | 0 |
| pdf-text | S2 | 150,359 | 150,357 | 1.0x | 0.0% | 20/20 | 20/20 | 0 |
| pdf-text | S3 | 217,661 | 217,697 | 1.0x | \-0.0% | 20/20 | 20/20 | 0 |
| pptx | S1 | 126,448 | 887,386 | 0.1x | \-601.8% | 4/20 | 18/20 | \+14 |
| **pptx** | **S2** | **872,298** | **191,744** | **4.5x** | **78.0%** | 18/20 | 16/20 | \-2 |
| **pptx** | **S3** | **1,330,060** | **194,317** | **6.8x** | **85.4%** | 16/20 | 18/20 | \+2 |
| xlsx | S1 | 323,710 | 396,220 | 0.8x | \-22.4% | 8/20 | 10/20 | \+2 |
| **xlsx** | **S2** | **595,746** | **258,756** | **2.3x** | **56.6%** | 10/20 | 10/20 | 0 |
| xlsx | S3 | 330,315 | 326,740 | 1.0x | 1.1% | 9/20 | 10/20 | \+1 |

**\!\!\!** \= Benchmark bug. DOCX S2 native scored 0/20 because Claude read the wrong file (S2.pdf instead of S2.docx) in 2 of 3 runs. When it read the right file, it scored 20/20. See “Discovery 2” above.

**How Claude Code’s Read tool handles each format natively:**

| Format | Read Tool Behavior | Claude’s Workaround | Hook Value |
| :---- | :---- | :---- | :---- |
| PDF | Native API support (base64 → document block) | N/A \- works natively | **None** |
| HTML | Raw text pass-through | N/A \- works natively | **None** |
| DOCX | Rejected as binary | Bash: textutil, unzip (5-8 turns) | Convenience only |
| XLSX | Rejected as binary | Bash: various extraction (5-16 turns) | Mixed |
| PPTX | Rejected as binary | **None \- Claude gives up** | Real gap (but overkill) |
| Markdown | Native text read | N/A | **Harmful** (-154% in v1) |

**Methodology**: Each cell run 3 times, median reported. Quality scored on 10 factual questions (0/1/2 points each, max 20). Token counts include all input tokens (direct \+ cache creation \+ cache read). Environment: Claude Code 2.1.89, markitdown 0.0.2, Claude Haiku 4.5, macOS ARM64.
