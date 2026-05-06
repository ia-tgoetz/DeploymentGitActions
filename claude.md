# Project Context: Automated Ignition 8.3 Edge Deployment

## Goal
Automate the deployment and configuration sync of Inductive Automation's Ignition 8.3 Edge on field Industrial PCs (IPCs) using Docker and GitHub Actions.

## Environment & Constraints
- **Platform:** Ignition 8.3 (File-based/Git-native configuration).
- **Containerization:** Docker & Docker Compose.
- **Agent:** GitHub Actions (Self-Hosted Runner) deployed on the IPC host OS.
- **Offline/Local Image Requirement:** The Docker image should be managed alongside this repository/deployment process rather than dynamically pulling from Docker Hub on the IPC. 

## Request for Claude
Please act as a DevOps architect. Analyze the constraints above and provide recommendations, file structures, and code for the following components:

### 1. Docker Architecture & Compose File
- Recommend the best way to handle, store, and load the Ignition Docker image locally on the IPC given the constraints.
- Draft a `docker-compose.yml` for Ignition 8.3 Edge.
- **Provide input on storage:** How should we structure the bind mounts or volumes so that we can sync Git files (like projects and gateway configs) to the container without overwriting essential core files needed for Ignition's initial boot?

### 2. GitHub Actions Workflow (`deploy.yml`)
- Draft a workflow that triggers on a push to the `main` branch.
- Define the optimal sequence of steps for the Self-Hosted Runner to:
    1. Update the local filesystem.
    2. Manage the MQTT certificates (stored in GitHub Secrets).
    3. Safely cycle or update the Docker container to apply the new configurations.

### 3. Repository Directory Structure
- Recommend an optimal folder structure for this Git repository.
- We need to house Ignition 8.3 projects, gateway network configurations, device connections, MQTT settings, and the deployment scripts. Please outline where these should live.

### 4. Technical Hurdles to Address
Please provide solutions or best practices for:
- **Permissions:** Allowing the GitHub Runner to execute Docker commands on the host OS seamlessly.
- **Gateway Network:** Exposing the correct ports (e.g., 8088/8043) through Docker so the IPC can communicate with a central gateway.
- **Initial Setup:** Automating the EULA acceptance and initial admin password creation upon the container's first boot.