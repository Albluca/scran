.buildSNNGraph <- function(x, k=10, d=50, subset.row=NULL, BPPARAM=SerialParam())
# Builds a shared nearest-neighbor graph, where edges are present between each 
# cell and its 'k' nearest neighbours. Edges are weighted based on the ranks of 
# the shared nearest neighbours of the two cells, as described in the SNN-Cliq paper.
#
# written by Aaron Lun
# created 3 April 2017
# last modified 26 June 2017    
{ 
    ncells <- ncol(x)
    if (!is.null(subset.row)) {
        x <- x[.subset_to_index(subset.row, x, byrow=TRUE),,drop=FALSE]
    }
    
    # Reducing dimensions, if 'd' is less than the number of genes.
    x <- t(x)
    if (!is.na(d) && d < ncol(x)) {
        pc <- prcomp(x, rank.=d)
        x <- pc$x
    }

    # Getting the kNNs.
    nn.out <- .find_knn(x, k=k, BPPARAM=BPPARAM, algorithm="cover_tree") 

    # Building the SNN graph.
    g.out <- .Call(cxx_build_snn, nn.out$nn.index)
    if (is.character(g.out)) { stop(g.out) }
    edges <- g.out[[1]] 
    weights <- g.out[[2]]

    g <- make_graph(edges, directed=FALSE)
    E(g)$weight <- weights
    g <- simplify(g, edge.attr.comb="first") # symmetric, so doesn't really matter.
    return(g)
}

.find_knn <- function(incoming, k, BPPARAM, ..., force=FALSE) {
    # Some checks to avoid segfauls in get.knn(x).
    ncells <- nrow(incoming)
    if (ncol(incoming)==0L || ncells==0L) { 
        return(list(nn.index=matrix(0L, ncells, 0), nn.dist=matrix(0, ncells, 0)))
    }
    if (k >= nrow(incoming)) {
        warning("'k' set to the number of cells minus 1")
        k <- nrow(incoming) - 1L
    }

    nworkers <- bpworkers(BPPARAM)
    if (!force && nworkers==1L) {
        # Simple call with one core.
        nn.out <- get.knn(incoming, k=k, ...)
    } else {
        # Splitting up the query cells across multiple cores.
        by.group <- .worker_assign(ncells, BPPARAM)
        x.by.group <- vector("list", nworkers)
        for (j in seq_along(by.group)) {
            x.by.group[[j]] <- incoming[by.group[[j]],,drop=FALSE]
        } 
        all.out <- bplapply(x.by.group, FUN=get.knnx, data=incoming, k=k+1, ..., BPPARAM=BPPARAM)
        
        # Some work to get rid of self as a nearest neighbour.
        for (j in seq_along(all.out)) {
            cur.out <- all.out[[j]]
            is.self <- cur.out$nn.index==by.group[[j]]
            ngenes <- nrow(is.self)
            no.hits <- which(rowSums(is.self)==0)
            to.discard <- c(which(is.self), no.hits + k*ngenes) # getting rid of 'k+1'th, if self is not present.

            new.nn.index <- cur.out$nn.index[-to.discard]
            new.nn.dist <- cur.out$nn.dist[-to.discard]
            dim(new.nn.index) <- dim(new.nn.dist) <- c(ngenes, k)
            cur.out$nn.index <- new.nn.index
            cur.out$nn.dist <- new.nn.dist
            all.out[[j]] <- cur.out
        }

        # rbinding everything together.
        nn.out <- do.call(mapply, c(all.out, FUN=rbind, SIMPLIFY=FALSE))
    }
    return(nn.out)
}

setGeneric("buildSNNGraph", function(x, ...) standardGeneric("buildSNNGraph"))

setMethod("buildSNNGraph", "matrix", .buildSNNGraph)

setMethod("buildSNNGraph", "SCESet", function(x, ..., subset.row=NULL, assay="exprs", get.spikes=FALSE) {
    if (is.null(subset.row)) { 
        subset.row <- .spike_subset(x, get.spikes)
    }
    .buildSNNGraph(assayDataElement(x, assay), ..., subset.row=subset.row)
})
