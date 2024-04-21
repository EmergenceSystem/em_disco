use actix_web::{post, HttpResponse, Responder, web};
use std::collections::{HashSet};
use tokio::sync::{mpsc, Mutex};
use serde::Deserialize;
use std::time::{Duration, Instant};
use tokio::time::timeout;
use lazy_static::lazy_static;
use embryo::EmbryoList;

const TIMEOUT:u64 = 10;

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
    sender: mpsc::Sender<EmbryoList>,
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
            sender.send(filter_response).await.unwrap_or_else(|err| {
                eprintln!("Error sending filter response to channel: {:?}", err);
            });
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
    let filter_urls = {
        FilterRegistry::get_instance().lock().await.iter().cloned().collect::<Vec<String>>()
    };

    let mut tasks = Vec::new();

    // Create channels for each filter URL
    let mut receivers = Vec::new();
    for url in filter_urls {
        let (sender, receiver) = mpsc::channel::<EmbryoList>(1);
        receivers.push(receiver);
        tasks.push(call_filter(url, body.clone(), sender));
    }

    // Wait for all tasks to finish
    for task in tasks {
        tokio::spawn(async move {
            task.await.unwrap_or_default();
        });
    }

    // Aggregate results
    let mut aggregated_list = Vec::new();
    for mut receiver in receivers {
        tokio::select! {
            result = receiver.recv() => {
                if let Some(result) = result {
                    aggregated_list = embryo::merge_lists_by_url(aggregated_list, result.embryo_list);
                }
            }
            _ = tokio::time::sleep(Duration::from_secs(TIMEOUT)) => {
                // Handle timeout
                println!("Timeout occurred while waiting for filter response");
            }
        }
    }

    HttpResponse::Ok().json(EmbryoList { embryo_list: aggregated_list })
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

