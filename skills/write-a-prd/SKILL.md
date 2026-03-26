---
name: write-a-prd
description: Create a PRD through user description, codebase exploration, and autonomous gap-filling, then submit as a GitHub issue or local file. Use when user wants to write a PRD, create a product requirements document, or plan a new feature.
---

# Write a PRD

Create a PRD from the user's description. The user's job is the vision and specific requirements. Your job is structure, technical enhancement, and filling gaps autonomously.

## Process

### 1. Get the user's description

Ask the user to describe what they want to build. They should be specific about:

- The problem they are solving
- Features they want
- Constraints or preferences (tech stack, deployment, integrations)
- Anything they feel strongly about

Let them write as much or as little as they want. Do NOT interrogate -- if they gave you enough to work with, move forward.

### 2. Explore the codebase

If there is an existing codebase, explore it to understand the current architecture, patterns, and integration points. This informs your technical decisions.

### 3. Fill gaps autonomously

Based on the user's description and codebase exploration, make decisions about anything the user did not specify:

- Tech stack (prefer agentic-first: CLI-friendly, hot-reload, easy to test and automate)
- Architecture and data model
- API design
- AI self-modification surface (chat panel, /ai endpoint, or similar)
- Testing approach
- Edge cases and error handling

Do NOT ask the user about each of these. Make reasonable choices and include them in the PRD. The user can revise after seeing the full picture.

### 4. One round of feedback

Present a brief summary of what you plan to write:

- Problem + solution (2-3 sentences each)
- Key features (bulleted list)
- Technical decisions you made autonomously

Ask: "Does this match your vision? Anything to add, remove, or change?"

One round. Then write the PRD.

### 5. Write the PRD

Use the template below. Submit as a GitHub issue if in a repo, otherwise save to a local file.

<prd-template>

## Problem

The problem from the user's perspective. 2-4 sentences.

## Solution

What will be built. Concrete enough to plan from, abstract enough to leave implementation flexibility. 3-6 sentences.

## Requirements

Specific, testable requirements grouped by area. These become the acceptance criteria when the plan is built. Each requirement should be verifiable -- an evaluator agent should be able to test it.

### Core features
- Requirement 1
- Requirement 2
- ...

### AI integration
- How the app exposes self-modification (chat panel, /ai command, etc.)
- ...

### UX / interface
- ...

### Data / persistence
- ...

(Add or remove sections as appropriate for the project.)

## Technical decisions

Decisions made during PRD creation. These carry forward into the plan.

- **Stack**: chosen technologies and why
- **Architecture**: high-level structure
- **Data model**: key entities and relationships
- **API surface**: routes, endpoints, or CLI commands
- **Testing**: approach and tools

Do NOT include specific file paths or code snippets -- they become outdated quickly.

## Out of scope

What this PRD explicitly does NOT cover. Helps prevent scope creep during implementation.

## Open questions

Anything unresolved that should be decided during planning or implementation. If empty, omit this section.

</prd-template>
