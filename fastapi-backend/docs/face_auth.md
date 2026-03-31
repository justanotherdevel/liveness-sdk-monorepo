# Face Authentication Backend Setup

This document outlines how to deploy the FastAPI backend using Docker/Podman, and successfully install the required `buffalo_l` face recognition model.

## 1. Directory Structure Prep
For `insightface` to properly detect the `buffalo_l` model, the models must be placed inside the `fastapi-backend/models/models/buffalo_l/` directory before building/running the docker container.

```bash
liveness-sdk-monorepo/
└── fastapi-backend/
    ├── models/
    │   └── models/
    │       └── buffalo_l/
    │           ├── 1k3d68.onnx
    │           ├── 2d106det.onnx
    │           ├── det_10g.onnx
    │           ├── genderage.onnx
    │           └── w600k_r50.onnx
    ├── main.py
    ├── Dockerfile
    └── ...
```

*(Note: Ensure you download the `buffalo_l` models [from the official insightface repository](https://github.com/deepinsight/insightface/tree/master/python-package) and extract the contents entirely into that directory).*

## 2. Compiling and Running with Podman
You can build the completely self-contained podman image directly from the `fastapi-backend` directory. 

### Build the Image
```bash
podman build -t liveness-backend .
```

### Run the Container
```bash
podman run -d -p 8000:8000 --name liveness-api liveness-backend
```

### Accessing the API
The API will be available at `http://localhost:8000`. You can test endpoints identically or hit `http://localhost:8000/docs` to see the auto-generated Swagger UI for visually debugging the requests natively on your browser!
