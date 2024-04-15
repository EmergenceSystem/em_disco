use actix_web::{post, HttpResponse, Responder, web};
use std::collections::{HashSet};
use tokio::sync::{mpsc, Mutex};
use serde::Deserialize;
use std::time::{Duration, Instant};
use tokio::time::timeout;
use lazy_static::lazy_static;
use embryo::{Embryo, EmbryoList};

static MAX_RESPONSE:i32 = 5;

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

    let result = timeout(Duration::from_secs(5),
    reqwest::Client::new()
    .post(&filter_url)
    .header(reqwest::header::CONTENT_TYPE, "application/json")
    .body(format!("{{\"value\":\"{}\"}}", body))
    .send())
        .await;

    match result {
        Ok(res) => {
            println!("Filter request completed in {:?}", start_time.elapsed());

            let body = res?.text().await?.to_string();

            let filter_response: EmbryoList = serde_json::from_str(&body)?;
            sender.send(filter_response).await.unwrap_or_else(|err| {
                eprintln!("Error sending filter response to channel: {:?}", err);
            });
        }
        Err(err) => {
            eprintln!("Error calling filter: {:?}", err);
        }
    }

    Ok(())
}

#[post("/query")]
async fn aggregate_handler(body: String) -> impl Responder {
    let mut tasks = Vec::new();
    let mut completed_tasks = 0;

    let filter_urls = {
        FilterRegistry::get_instance().lock().await.iter().cloned().collect::<Vec<String>>()
    };

    let (sender, mut receiver) = mpsc::channel::<EmbryoList>(filter_urls.len());

    for url in filter_urls {
        tasks.push(Box::pin(call_filter(url.clone(), body.clone(), sender.clone())));
    }

    // wait for all tasks
    for task in tasks {
        task.await.unwrap_or_default();
    }

    drop(sender); // close channel

    let mut aggregated_list = Vec::new();

    while let Some(result) = receiver.recv().await {
        completed_tasks += 1;
        aggregated_list = merge_lists(aggregated_list, result.embryo_list);

        if completed_tasks >= MAX_RESPONSE {
            break;
        }
    }

    let res = EmbryoList { embryo_list: aggregated_list };

    HttpResponse::Ok().json(res)
}

fn merge_lists(mut uri_list: Vec<Embryo>, other_list: Vec<Embryo>) -> Vec<Embryo> {
    uri_list.extend(other_list);

    let mut added_elements = HashSet::new();

    let result: Vec<_> = uri_list
        .into_iter()
        .filter(|embryo| {
            let has_duplicate_url = embryo.properties.iter().any(|(name, value)| {
                name == "url" && !added_elements.insert(value.clone())
            });

            !has_duplicate_url
        })
    .collect();

    result
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

