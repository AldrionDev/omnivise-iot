# OmniVise-IoT: High-Throughput IoT Monitoring Platform

**OmniVise-IoT** is a cloud-native monitoring ecosystem designed for high-frequency sensor data. It utilizes a lightweight **Javalin** backend, a schema-less **MongoDB** data store, and a modern **React** frontend, all orchestrated via **Kubernetes** and **Terraform** on **AWS**.

---

## � The Mission

Modern smart homes generate vast amounts of unstructured telemetry data. This project solves the challenge of capturing, storing, and visualizing this data in real-time using a **NoSQL** approach, ensuring the system remains scalable even as the number of "smart devices" grows.

### Architecture Highlights:

- **Javalin Microservice:** An ultra-lightweight Java web framework for handling RESTful ingestion and WebSocket broadcasting.
- **MongoDB Time-Series:** Optimized storage for temporal sensor data (Temperature, Humidity, Power usage).
- **React Dashboard:** A dynamic, WebSocket-powered UI with real-time charting.
- **Infrastructure as Code:** A complete AWS environment defined in **Terraform**.
- **DevOps Excellence:** Fully containerized with **Docker** and managed by **Kubernetes (EKS)**.

---

## � Technology Stack

| Layer           | Technologies                                             |
| --------------- | -------------------------------------------------------- |
| **Backend**     | Java 17+, **Javalin**, MongoDB Java Driver, Jackson      |
| **Frontend**    | React 18, Tailwind CSS, Lucide Icons, Chart.js           |
| **Database**    | **MongoDB (Time-series collections)**                    |
| **Messaging**   | WebSockets (Native Javalin implementation)               |
| **DevOps**      | Docker, Docker Compose, Kubernetes (K8s)                 |
| **Cloud (AWS)** | EKS (Kubernetes), DocumentDB (or MongoDB Atlas), VPC, S3 |
| **IaC**         | **Terraform** (Remote State, Modular Design)             |

---

## � System Design

1. **Simulators:** Independent Java threads/processes act as IoT devices sending JSON payloads.
2. **Ingestion:** Javalin receives data, validates it, and asynchronously writes to **MongoDB**.
3. **Real-time Push:** Upon successful write, the backend pushes the update to all connected React clients via **WebSockets**.
4. **Scaling:** Kubernetes **HPA** scales the Javalin pods based on the incoming request load.
5. **Provisioning:** Terraform automates the networking (VPC), database, and compute (EKS) layers.

---

## � Project Structure

```bash
/omnivise-iot
├── /backend        # Javalin microservice
├── /frontend       # React + Tailwind UI
├── /simulators     # Java IoT device emulators
├── /terraform      # IaC: AWS VPC, EKS, and MongoDB clusters
├── /k8s            # Kubernetes manifests (Deployments, Services, HPA)
└── /docker         # Multi-stage Dockerfiles & Docker Compose

```

---

## � Quick Start

### 1. Local Environment (Docker Compose)

Launch the entire ecosystem (DB + Backend + Frontend) with one command:

```bash
docker-compose up --build

```

- **Frontend:** `http://localhost:3000`
- **Backend API:** `http://localhost:8080`
- **MongoDB Express (UI):** `http://localhost:8081`

### 2. Cloud Deployment (Terraform)

```bash
cd terraform
terraform init
terraform apply -auto-approve

```

---

## � Key Features for Interviewers

- **NoSQL Data Modeling:** Leverages MongoDB’s flexible schema to handle different sensor types without migrations.
- **Event-Driven UI:** Uses WebSockets instead of polling for a true real-time experience.
- **Cloud-Native Scalability:** Demonstrates how to use Terraform and Kubernetes to build a production-grade environment.
- **Self-Healing:** Kubernetes probes ensure the Javalin API stays healthy.

---

## � Future Improvements

- [ ] Implement JWT-based authentication for private home monitoring.
- [ ] Add Prometheus/Grafana dashboard for infrastructure metrics.
- [ ] Integrate AWS Lambda for periodic data archiving.

---
