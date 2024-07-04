# MultiModal Search on Fess

[Fess](https://fess.codelibs.org/) is an Enterprise Search Server. This Docker environment sets up a MultiModal Search Server on Fess.

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

## Additional Information

### Test Data

To download 1000 images for testing, use the following commands. The images will be available in the `/home/fiftyone/validation/data` directory of the Fess container.

1. Install FiftyOne:
    ```sh
    pip install fiftyone
    ```

2. Download the dataset:
    ```sh
    fiftyone zoo datasets load open-images-v7 --split validation --kwargs max_samples=1000 -d ./data/fiftyone
    ```

---

For additional support or information, please visit the [Fess documentation](https://fess.codelibs.org/).
