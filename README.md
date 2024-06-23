# MultiModal Search on Fess

[Fess](https://fess.codelibs.org/) is an Enterprise Search Server. This Docker environment sets up a MultiModal Search Server on Fess.

## Public Site

Visit our public site at [multimodal.codelibs.org](https://multimodal.codelibs.org/).

## Getting Started

### Prerequisites

Ensure you have Docker and Git installed on your system.

### Setup

1. Clone the repository:
    ```sh
    git clone https://github.com/codelibs/docker-multimodalsearch.git
    cd docker-multimodalsearch
    ```

2. Run the setup script:
    ```sh
    bash ./bin/setup.sh
    ```

### Start the Server

Start the server using Docker Compose:
```sh
docker compose -f compose.yaml up -d
```
Once started, access the server at `http://localhost:8080/`.

### Reindex Data

1. Navigate to **Admin** > **Maintenance**.
2. Start the reindexing process.

Your multimodal search setup on Fess is now complete and ready to use.

### Stop the Server

To stop the server, run:
```sh
docker compose -f compose.yaml down
```

## For Production

To deploy in a production environment, update `compose-production.yaml` with your domain, replacing `multimodal.codelibs.org`.

---

For additional support or information, please visit the [Fess documentation](https://fess.codelibs.org/).
