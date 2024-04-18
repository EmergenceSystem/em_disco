use actix_web::{post, HttpResponse, Responder, web};
use actix_web::http::StatusCode;
use std::collections::{HashSet};
use tokio::sync::Mutex;
use tokio::time::timeout;
use serde::Deserialize;
use std::time::{Duration, Instant};
use lazy_static::lazy_static;
use serde_json::Value;
use embryo::EmbryoList;

const TIMEOUT:u64 = 15;

#[derive(Deserialize)]
struct FilterInfo {
    url: String,
}

#[derive(Default)]
struct FilterRegistry;

lazy_static! {
    static ref FILTER_REGISTRY: Mutex<HashSet<String>> = Mutex::new(HashSet::new());
}

impl FilterRegistry {
    async fn register_filter(url: String) {
        let mut urls = FILTER_REGISTRY.lock().await;
        urls.insert(url.clone());
        println!("Filter registered: {}", url);
    }

    async fn unregister_filter(url: &str) {
        let mut urls = FILTER_REGISTRY.lock().await;
        urls.remove(url);
        println!("Filter unregistered: {}", url);
    }

    fn get_instance() -> &'static Mutex<HashSet<String>> {
        &*FILTER_REGISTRY
    }
}

#[post("/register")]
async fn register_filter(info: web::Json<FilterInfo>) -> impl Responder {
    let filter_url = info.url.clone();
    FilterRegistry::register_filter(filter_url.clone()).await;

    HttpResponse::Ok().finish()
}

#[post("/unregister")]
async fn unregister_filter(info: web::Json<FilterInfo>) -> impl Responder {
    let filter_url = info.url.clone();
    FilterRegistry::unregister_filter(&filter_url).await;

    HttpResponse::Ok().finish()
}

async fn call_filter(
    filter_url: String,
    body: String,
    embox_url: String
    ) -> Result<(), Box<dyn std::error::Error>> {

    let start_time = Instant::now();

    println!("Called filter {}", filter_url);

    let result = match timeout(Duration::from_secs(TIMEOUT),
    reqwest::Client::new()
    .post(&filter_url)
    .header(reqwest::header::CONTENT_TYPE, "application/json")
    .body(format!("{{\"value\":\"{}\",\"timeout\":\"{}\"}}", body, TIMEOUT - 1))
    .send())
        .await {
            Ok(res) => res,
            Err(err) => {
                eprintln!("Failed to send HTTP request to {} : \n\t{}", filter_url, err);
                return Ok(());
            }
        };

    match result {
        Ok(res) => {
            println!("Filter request completed in {:?}", start_time.elapsed());

            let body = res.text().await?.to_string();

            let filter_response: EmbryoList = serde_json::from_str(&body)?;
            let filter_response_json = match serde_json::to_string(&filter_response) {
                Ok(json) => json,
                Err(err) => {
                    eprintln!("Failed to serialize filter response to JSON: {}", err);
                    String::new()
                }
            };

            match reqwest::Client::new()
                .post(&embox_url)
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(filter_response_json)
                .send()
                .await {
                    Ok(_) => println!("Send to Embox {}: ok", embox_url),
                    Err(err) => println!("Error to send to Embox {} {:?}", embox_url, err),
                }
        }
        Err(err) => {
            eprintln!("Error calling filter thus removing this filter {} : {}", filter_url, err);
            // unregister
            FilterRegistry::unregister_filter(&filter_url).await;
        }
    }

    Ok(())
}


#[post("/query")]
async fn aggregate_handler(body: String) -> impl Responder {
    let json_value: Value = match serde_json::from_str(&body) {
        Ok(value) => value,
        Err(err) => {
            eprintln!("Failed to deserialize JSON: {}", err);
            Value::Null
        }
    };
    let query = json_value
        .get("query")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_default();
    let embox_url = json_value
        .get("embox_url")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_default();

    let filter_urls = {
        FilterRegistry::get_instance().lock().await.iter().cloned().collect::<Vec<String>>()
    };

    tokio::spawn(async move {
        if !filter_urls.is_empty() {
            for url in filter_urls {
                let _ = call_filter(url.clone(), query.to_string(), embox_url.to_string()).await;
            }
        }
    });

    HttpResponse::build(StatusCode::OK).finish()
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    actix_web::HttpServer::new(|| {
        actix_web::App::new()
            .service(register_filter)
            .service(unregister_filter)
            .service(aggregate_handler)
    })
    .bind("0.0.0.0:8080")?
        .run()
        .await
}

