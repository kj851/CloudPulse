# FinOps Dashboard

## Overview

FinOps is a desktop wrapper and dashboard for analyzing and optimizing cloud costs across AWS, Azure, and GCP. The app combines an R/Shiny backend with a small Python desktop launcher for a native experience.

## Features

- Real-time cost monitoring
- Budget alerts and notifications
- Cost optimization recommendations and tips
- Interactive charts and graphs
- Multi-cloud support (AWS, Azure, GCP)

## Prerequisites

- Python 3.8+ with `PyQt5` and `PyQtWebEngine` (see `requirements.txt`)
- R (4.x recommended) with packages listed in `install_R_packages.R`

## Installation & Run (local)

1. Clone the repository:

```bash
git clone https://github.com/kj851/CloudPulse/tree/main#
cd CloudPulse
```

2. Install Python dependencies:

```bash
python3 -m pip install -r requirements.txt
```

3. Install R package dependencies (see `install_R_packages.R`):

```bash
Rscript install_R_packages.R
```

4. Launch the app (desktop wrapper):

```bash
./run_app.sh
```

Alternatively, you can run the Shiny app directly from R:

```r
shiny::runApp('.')
```

## Usage

1. Use the desktop launcher to open the app window.
2. Select cloud provider, query type, and date ranges in the sidebar.
3. Enable forecasting or mock data for local testing.

## Contributing

Contributions welcome — open issues or pull requests with improvements.

Please follow these steps:

1. Fork the repository.
2. Create a feature branch.
3. Make your changes and commit.
4. Push to your fork and submit a pull request.

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.
3. Use the tips section to apply optimizations.
4. Set up alerts for budget thresholds.

## Support

For support, please contact repo owner or open an issue on GitHub.