# Contributing to PanelAlpha Snapshot Tool

Thank you for your interest in contributing to PanelAlpha Snapshot Tool! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [How to Contribute](#how-to-contribute)
- [Development Guidelines](#development-guidelines)
- [Pull Request Process](#pull-request-process)
- [Reporting Bugs](#reporting-bugs)
- [Feature Requests](#feature-requests)
- [Questions](#questions)

## Code of Conduct

This project adheres to a code of conduct. By participating, you are expected to uphold this code:

- Be respectful and inclusive
- Welcome newcomers and help them learn
- Focus on what is best for the community
- Show empathy towards other community members

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/PanelAlpha-Snapshot-Tool.git
   cd PanelAlpha-Snapshot-Tool
   ```
3. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## How to Contribute

### Types of Contributions

We welcome various types of contributions:

- **Bug fixes**: Fix issues reported in the issue tracker
- **Features**: Add new functionality to the tool
- **Documentation**: Improve or add documentation
- **Tests**: Add or improve test coverage
- **Performance**: Optimize existing code
- **Translations**: Add support for additional languages

### Before You Start

1. **Check existing issues** to see if someone is already working on it
2. **Open an issue** to discuss major changes before implementing them
3. **Read the documentation** to understand how the tool works

## Development Guidelines

### Code Style

- Follow existing code style and conventions
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions focused and concise

### Bash Script Guidelines

```bash
# Use strict mode
set -euo pipefail

# Use meaningful variable names
local snapshot_id="$1"
local target_dir="$2"

# Add error handling
if [[ ! -f "$file_path" ]]; then
    log ERROR "File not found: $file_path"
    return 1
fi

# Use consistent logging
log INFO "Starting operation..."
log DEBUG "Debug information"
log WARN "Warning message"
log ERROR "Error occurred"
```

### Security Best Practices

- Never log passwords or sensitive data
- Use secure file permissions (600 for config files)
- Validate and sanitize all user inputs
- Use secure temporary files
- Avoid command injection vulnerabilities

### Testing

Before submitting your changes:

1. **Test on a clean system** (preferably in a VM or container)
2. **Test both Control Panel and Engine** configurations
3. **Test all storage backends** (local, SFTP, S3)
4. **Verify backup and restore** operations work correctly
5. **Check error handling** with invalid inputs

### Documentation

- Update README.md if adding new features
- Update CHANGELOG.md following [Keep a Changelog](https://keepachangelog.com/) format
- Add inline comments for complex code
- Update help text if adding new options

## Pull Request Process

1. **Update documentation** to reflect your changes
2. **Update CHANGELOG.md** in the "Unreleased" section
3. **Ensure all tests pass** and code follows guidelines
4. **Create a pull request** with a clear description:
   - What changes were made
   - Why the changes were necessary
   - How to test the changes
   - Any breaking changes or migration notes

### Pull Request Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Performance improvement
- [ ] Code refactoring

## Testing
- [ ] Tested on Control Panel
- [ ] Tested on Engine
- [ ] Tested backup creation
- [ ] Tested restore operation
- [ ] Tested with local storage
- [ ] Tested with SFTP storage
- [ ] Tested with S3 storage

## Checklist
- [ ] Code follows project style guidelines
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] No sensitive data in commit
```

### Review Process

1. At least one maintainer will review your PR
2. Address any requested changes
3. Once approved, a maintainer will merge your PR
4. Your contribution will be credited in the release notes

## Reporting Bugs

### Before Submitting a Bug Report

1. **Check existing issues** to avoid duplicates
2. **Update to the latest version** and test again
3. **Collect relevant information**:
   - PanelAlpha version (Control Panel or Engine)
   - Operating system and version
   - Script version
   - Error messages and logs
   - Steps to reproduce

### Bug Report Template

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) when creating an issue.

```markdown
**Describe the bug**
Clear description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Run command '...'
2. See error '...'

**Expected behavior**
What you expected to happen.

**Environment**
- OS: [e.g., Ubuntu 22.04]
- PanelAlpha Type: [Control Panel / Engine]
- Script Version: [e.g., 1.1.0]
- Docker Version: [e.g., 24.0.5]

**Logs**
```bash
# Relevant log entries from /var/log/pasnap.log
```

**Additional context**
Any other information about the problem.
```

## Feature Requests

We welcome feature requests! Please:

1. **Search existing issues** to avoid duplicates
2. **Describe the feature** clearly and provide use cases
3. **Explain why it would be useful** to the community
4. **Consider implementation complexity** and maintenance burden

### Feature Request Template

```markdown
**Is your feature request related to a problem?**
Clear description of the problem.

**Describe the solution you'd like**
Clear description of what you want to happen.

**Describe alternatives you've considered**
Any alternative solutions or features you've considered.

**Use cases**
Describe specific use cases for this feature.

**Additional context**
Any other context or screenshots about the feature request.
```

## Questions

Have questions about the project? You can:

1. **Check the documentation** in [README.md](README.md)
2. **Search existing issues** for similar questions
3. **Create a discussion** for general questions
4. **Open an issue** with the "question" label

## Development Setup

### Prerequisites

- Ubuntu 18.04+ or compatible Linux
- Docker 20.10+
- Docker Compose 1.29+
- Bash 4.0+
- Git

### Local Testing Environment

```bash
# Create a test environment
docker run -it --rm \
  -v $(pwd):/workspace \
  -w /workspace \
  ubuntu:22.04 \
  bash

# Inside container, install dependencies
apt update
apt install -y docker.io docker-compose restic jq rsync

# Test the script
./pasnap.sh --help
```

### Testing Checklist

- [ ] Script runs without errors
- [ ] Help text displays correctly
- [ ] Version information is accurate
- [ ] Configuration setup works
- [ ] Backup creation succeeds
- [ ] Restore operation succeeds
- [ ] Cron automation installs correctly
- [ ] Error handling works as expected
- [ ] Log files are created properly
- [ ] Temporary files are cleaned up

## Release Process

(For maintainers)

1. Update version in `pasnap.sh`
2. Update CHANGELOG.md
3. Create git tag: `git tag -a v1.x.x -m "Release v1.x.x"`
4. Push tag: `git push origin v1.x.x`
5. Create GitHub release with changelog

## Recognition

Contributors will be recognized in:
- CHANGELOG.md release notes
- GitHub contributors page
- Special thanks section (for significant contributions)

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.

---

Thank you for contributing to PanelAlpha Snapshot Tool! 🎉
