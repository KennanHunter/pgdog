use crate::sync::SetOnceCell;
use crate::{
    backend::{Error, Server},
    net::DataRow,
};
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Default, Debug)]
/// The mapping from a shards type OID to a canonical one
pub(crate) struct Oids {
    canonical_oids: Arc<CanonicalOids>,
    oids: SetOnceCell<HashMap<u32, u32>>,
}

impl Oids {
    pub(crate) fn new(canonical_oids: Arc<CanonicalOids>) -> Self {
        Self {
            canonical_oids,
            oids: Default::default(),
        }
    }

    pub(crate) async fn load(&self, server: &mut Server) -> Result<&HashMap<u32, u32>, Error> {
        self.oids
            .get_or_try_init(|| async {
                let oids = load_oids(server).await?;
                let canonical = self.canonical_oids.oids.wait().await;
                Ok(oids
                    .map(|(type_name, oid)| {
                        (oid, canonical.get(&type_name).copied().unwrap_or(oid))
                    })
                    .collect())
            })
            .await
    }

    pub(crate) async fn wait(&self) -> &HashMap<u32, u32> {
        self.oids.wait().await
    }
}

#[derive(Debug, Default)]
pub(crate) struct CanonicalOids {
    oids: SetOnceCell<HashMap<String, u32>>,
}

impl CanonicalOids {
    pub(crate) async fn load(&self, server: &mut Server) -> Result<(), Error> {
        self.oids
            .get_or_try_init(|| async { Ok(load_oids(server).await?.collect()) })
            .await
            .map(|_| ())
    }

    pub(crate) fn skip_load(&self) {
        let _ = self.oids.set(Default::default());
    }
}

async fn load_oids(server: &mut Server) -> Result<impl Iterator<Item = (String, u32)>, Error> {
    Ok(server
        .fetch_all::<DataRow>("SELECT typname, pg_type.oid FROM pg_type WHERE pg_type.oid >= 10000")
        .await?
        .into_iter()
        .map(|row| {
            (
                row.get_text(0).unwrap_or_default(),
                row.get_int(1, true).unwrap_or_default() as u32,
            )
        }))
}
