import os
import argparse
import pandas as pd
import mlflow
import mlflow.sklearn
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import classification_report
from sklearn.model_selection import train_test_split


def main():
    # ── argumentos de entrada ──────────────────────────────────────────────────
    parser = argparse.ArgumentParser()
    parser.add_argument("--data",                  type=str,   help="ruta al CSV de entrada")
    parser.add_argument("--test_train_ratio",      type=float, default=0.25)
    parser.add_argument("--n_estimators",          type=int,   default=100)
    parser.add_argument("--learning_rate",         type=float, default=0.1)
    parser.add_argument("--registered_model_name", type=str,   help="nombre del modelo en el registry")
    args = parser.parse_args()

    # ── iniciar MLflow ─────────────────────────────────────────────────────────
    mlflow.start_run()
    # FIX: log_models=False evita que autolog use la API create_logged_model
    # (no soportada por Azure ML con MLflow >= 2.13)
    mlflow.sklearn.autolog(log_models=False)

    # ── cargar datos ───────────────────────────────────────────────────────────
    print(f"Cargando datos desde: {args.data}")
    credit_df = pd.read_csv(args.data, header=1, index_col=0)

    mlflow.log_metric("num_samples",  credit_df.shape[0])
    mlflow.log_metric("num_features", credit_df.shape[1] - 1)

    print(f"Dataset cargado: {credit_df.shape[0]} filas, {credit_df.shape[1]} columnas")
    print(f"Distribucion del target:")
    print(credit_df["default payment next month"].value_counts())

    # ── dividir en train/test ──────────────────────────────────────────────────
    train_df, test_df = train_test_split(credit_df, test_size=args.test_train_ratio, random_state=42)

    y_train = train_df.pop("default payment next month")
    X_train = train_df.values

    y_test  = test_df.pop("default payment next month")
    X_test  = test_df.values

    print(f"Train: {X_train.shape} | Test: {X_test.shape}")

    # ── entrenar el modelo ─────────────────────────────────────────────────────
    clf = GradientBoostingClassifier(
        n_estimators  = args.n_estimators,
        learning_rate = args.learning_rate,
        random_state  = 42
    )
    clf.fit(X_train, y_train)

    y_pred = clf.predict(X_test)
    print("\nReporte de clasificacion:")
    print(classification_report(y_test, y_pred, target_names=["No default", "Default"]))

    # ── guardar y registrar el modelo ──────────────────────────────────────────
    print(f"Registrando modelo como: {args.registered_model_name}")

    conda_env = {
        'name': 'mlflow-env',
        'channels': ['conda-forge'],
        'dependencies': [
            'python=3.10.15',
            {'pip': [
                'mlflow==2.17.0',
                'pandas==1.5.3',
                'scikit-learn==1.5.2',
                'numpy==1.26.4',
            ]}
        ],
    }

    # FIX: NO pasar registered_model_name aqui — en MLflow >= 2.13 eso llama
    # create_logged_model que devuelve 404 en Azure ML. Registramos abajo.
    mlflow.sklearn.log_model(
        sk_model      = clf,
        artifact_path = args.registered_model_name,
        conda_env     = conda_env,
    )

    mlflow.sklearn.save_model(
        sk_model = clf,
        path     = os.path.join(args.registered_model_name, "trained_model"),
    )

    # FIX: registrar el modelo usando register_model (API clasica, siempre compatible)
    run_id    = mlflow.active_run().info.run_id
    model_uri = f"runs:/{run_id}/{args.registered_model_name}"
    mlflow.register_model(model_uri=model_uri, name=args.registered_model_name)
    print(f"Modelo registrado: {args.registered_model_name}")

    mlflow.end_run()
    print("Job completado.")


if __name__ == "__main__":
    main()
