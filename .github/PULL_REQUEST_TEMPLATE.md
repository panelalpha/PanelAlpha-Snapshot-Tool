name: Pull Request
description: Submit a pull request for review
title: "[PR] "
labels: ["pull-request"]

body:
  - type: markdown
    attributes:
      value: |
        Thanks for contributing to PanelAlpha Snapshot Tool!
        Please fill out this template to help us review your changes.

  - type: textarea
    id: description
    attributes:
      label: Description
      description: Provide a clear description of your changes
      placeholder: |
        What does this PR do?
        Why is this change needed?
        How does it work?
    validations:
      required: true

  - type: dropdown
    id: change-type
    attributes:
      label: Type of Change
      description: What type of change does this PR introduce?
      options:
        - Bug fix (non-breaking change which fixes an issue)
        - New feature (non-breaking change which adds functionality)
        - Breaking change (fix or feature that would cause existing functionality to not work as expected)
        - Documentation update
        - Performance improvement
        - Code refactoring
        - Tests
        - Other (please describe)
    validations:
      required: true

  - type: checkboxes
    id: testing
    attributes:
      label: Testing Checklist
      description: Which tests have been performed?
      options:
        - label: Tested on Control Panel
        - label: Tested on Engine
        - label: Tested backup creation
        - label: Tested restore operation
        - label: Tested with local storage
        - label: Tested with SFTP storage
        - label: Tested with S3 storage
        - label: Tested cron automation
        - label: Tested error handling

  - type: textarea
    id: test-description
    attributes:
      label: Testing Details
      description: Describe how you tested your changes
      placeholder: |
        1. Set up environment...
        2. Ran command...
        3. Verified output...
        4. Tested edge cases...

  - type: checkboxes
    id: breaking-changes
    attributes:
      label: Breaking Changes
      description: Does this PR introduce breaking changes?
      options:
        - label: This PR includes breaking changes
        - label: Migration guide included (if breaking changes)
        - label: Backward compatibility maintained

  - type: textarea
    id: breaking-details
    attributes:
      label: Breaking Changes Details
      description: If you checked breaking changes above, describe them here
      placeholder: |
        - Configuration format changed from X to Y
        - Command-line option renamed from --old to --new
        - Migration steps: ...

  - type: checkboxes
    id: checklist
    attributes:
      label: PR Checklist
      description: Please confirm the following
      options:
        - label: Code follows the project style guidelines
        - label: Self-review of code performed
        - label: Comments added for complex code
        - label: Documentation updated (README.md, help text, etc.)
        - label: CHANGELOG.md updated
        - label: No console.log or debug statements left
        - label: No sensitive data in commits
        - label: Commits are signed
    validations:
      required: true

  - type: textarea
    id: related-issues
    attributes:
      label: Related Issues
      description: Link any related issues
      placeholder: |
        Fixes #123
        Closes #456
        Related to #789

  - type: textarea
    id: screenshots
    attributes:
      label: Screenshots
      description: Add screenshots if applicable (especially for UI changes)

  - type: textarea
    id: additional-context
    attributes:
      label: Additional Context
      description: Add any other context about the PR here
      placeholder: |
        - Performance considerations
        - Known limitations
        - Future improvements
        - Questions for reviewers

  - type: checkboxes
    id: final-checks
    attributes:
      label: Final Checks
      description: Before submitting
      options:
        - label: I have read the CONTRIBUTING.md guidelines
        - label: I have tested this on a clean system
        - label: I have considered security implications
        - label: I am willing to address review feedback
    validations:
      required: true
