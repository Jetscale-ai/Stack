# JetScale AI Branching Strategy

JetScale AI follows a controlled trunk-based development model with the following branch conventions. This ensures code quality, maintainability, and smooth collaboration across all team members.

## Branch Protection & Standards

**main**: Protected production branch. Accepts only reviewed and approved pull requests that have passed all required checks.

- Requires pull request reviews before merging
- - Requires status checks to pass (CI/CD, tests, linting)
  - - Enforces up-to-date branches before merging
    - - Requires branches to be deleted after merging
     
      - ## Branch Naming Conventions
     
      - ### Feature Branches
     
      - **Naming Pattern**: `feature/*` or `feat/*` or `features/*`
     
      - Short-lived branches created from `main` for developing new features. Must be merged promptly or formally extended if development extends beyond 2 weeks.
     
      - Example: `feature/helm-chart-upgrade`, `feat/new-deployment-strategy`, `features/multiregion-support`
     
      - ### Bug Fix Branches
     
      - **Naming Pattern**: `bugfix/*` or `bug/*` or `fix/*`
     
      - Remediation branches for resolving bugs and issues. Subject to expedited review but never exempt from security controls.
     
      - Example: `bugfix/helm-values-validation`, `bug/image-registry-issue`, `fix/deployment-permissions`
     
      - ### Hotfix Branches
     
      - **Naming Pattern**: `hotfix/*` or `patch/*`
     
      - Urgent remediation branches for critical production issues. Require immediate review and testing.
     
      - Example: `hotfix/critical-service-deployment`, `patch/helm-release-issue`
     
      - ### Release Branches
     
      - **Naming Pattern**: `release/*` or `release-candidate/*`
     
      - Branches created for preparing production releases. Allow for final testing, version bumping, and documentation updates.
     
      - Example: `release/v1.5.0`, `release-candidate/v2.0.0`
     
      - ### Chore/Maintenance Branches
     
      - **Naming Pattern**: `chore/*` or `maintenance/*`
     
      - Branches for non-functional changes like dependency updates, code cleanup, refactoring, and infrastructure improvements.
     
      - Example: `chore/update-dependencies`, `maintenance/helm-linting`, `chore/cleanup-unused-charts`
     
      - ### Documentation Branches
     
      - **Naming Pattern**: `docs/*` or `documentation/*`
     
      - Branches dedicated to documentation updates, README changes, and knowledge base improvements.
     
      - Example: `docs/helm-deployment-guide`, `documentation/values-schema`
     
      - ### Experimental/Research Branches
     
      - **Naming Pattern**: `experiment/*` or `research/*` or `spike/*`
     
      - Branches for exploratory work, proof-of-concepts, and research tasks. These are typically short-lived and may not be merged to main.
     
      - Example: `experiment/new-helm-plugin`, `spike/container-registry-optimization`
     
      - ## Development Workflow
     
      - 1. **Create a branch** from `main` using the appropriate naming convention
        2. 2. **Implement changes** with clear, descriptive commits
           3. 3. **Test locally** using Tilt, Skaffold, or Kind
              4. 4. **Push to remote** regularly to prevent data loss
                 5. 5. **Create a Pull Request** when ready for review
                    6. 6. **Address review feedback** through additional commits
                       7. 7. **Merge** once all checks pass and approvals are received
                          8. 8. **Delete the branch** after merging
                            
                             9. ## Commit Message Guidelines
                            
                             10. Follow conventional commit format for consistency:
                            
                             11. ```
                                 <type>(<scope>): <subject>

                                 <body>

                                 <footer>
                                 ```

                                 Types: feat, fix, docs, style, refactor, perf, test, chore, ci
                                 Example: `feat(helm): add support for new deployment strategy`

                                 ## Best Practices

                                 - Keep branches short-lived (target: < 1 week of development)
                                 - - Use descriptive branch names that reflect the work being done
                                   - - Include issue numbers in branch names when applicable: `feature/helm-upgrade-#123`
                                     - - Regularly sync your branch with `main` to minimize merge conflicts
                                       - - Test changes locally before creating a pull request
                                         - - Write clear pull request descriptions
                                           - - Never force-push to `main` or shared branches
                                             - - Delete branches after merging to keep the repository clean
                                               - - Use `main` as the single source of truth for production-ready code
                                                
                                                 - ## Helm/Container Specific Guidelines
                                                
                                                 - - Always validate Helm charts: `helm lint charts/`
                                                   - - Test changes with local deployment tools (Tilt, Skaffold, Kind)
                                                     - - Document any new Helm values in the values schema
                                                       - - Ensure backward compatibility for existing deployments
                                                         - - Follow semantic versioning for chart versions
                                                           - - Test multi-cluster deployments when possible
                                                            
                                                             - ## Emergency Procedures
                                                            
                                                             - For critical production issues requiring immediate fixes:
                                                            
                                                             - 1. Create a `hotfix/*` branch from `main`
                                                               2. 2. Implement the minimal necessary changes
                                                                  3. 3. Test the fix locally before requesting review
                                                                     4. 4. Request expedited review
                                                                        5. 5. Merge directly to `main` once approved
                                                                           6. 6. Monitor the deployment closely
                                                                             
                                                                              7. ## Testing Requirements
                                                                             
                                                                              8. - All changes must pass local tests with Tilt/Skaffold
                                                                                 - - Helm chart linting must pass
                                                                                   - - Pull requests require CI/CD checks to pass
                                                                                     - - Documentation must be updated if values or behavior changes
                                                                                      
                                                                                       - ## Questions or Issues?
                                                                                      
                                                                                       - Refer to the repository's README or reach out to the platform team for clarification on branching practices.
