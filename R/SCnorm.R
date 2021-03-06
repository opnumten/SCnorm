#' @title SCnorm
#'
#' @param Data can be a matrix of single-cell expression with cells  
#'   where rows are genes and columns are samples. Gene names should
#'   not be a column in this matrix, but should be assigned to rownames(Data).
#'   Data can also be an object of class \code{SummarizedExperiment} that contains 
#'   the single-cell expression matrix and other metadata. The \code{assays} 
#'   slot contains the expression matrix and is named \code{"Counts"}.  
#'   This matrix should have one row for each gene and one sample for each column.  
#'   The \code{colData} slot should contain a data.frame with one row per 
#'   sample and columns that contain metadata for each sample.  This data.frame
#'   should contain a variable that represents biological condition 
#'   in the same order as the columns of \code{NormCounts}). 
#'   Additional information about the experiment can be contained in the
#'   \code{metadata} slot as a list.
#' @param Conditions vector of condition labels, this should correspond to
#'    the columns of the expression matrix.
#' @param PrintProgressPlots whether to automatically produce plot as SCnorm 
#'    determines the optimal number of groups (default is FALSE, highly 
#'    suggest using TRUE). Plots will be printed to the current device.
#' @param reportSF whether to provide a matrix of scaling counts in the
#'    output (default = FALSE).
#' @param FilterCellNum the number of non-zero expression estimate required
#'    to include the genes into the SCnorm fitting
#' (default = 10). The initial grouping fits a quantile regression to each
#'    gene, making this value too low gives unstable fits.
#' @param FilterExpression exclude genes having median of non-zero expression
#'    from the normalization.
#' @param Thresh threshold to use in evaluating the sufficiency of K, default
#'    is .1.
#' @param K the number of groups for normalizing. If left unspecified, an
#'    evaluation procedure will determine the optimal value of K
#'    (recommended). 
#' @param NCores number of cores to use, default is detectCores() - 1. 
#' This will be used to set up a parallel environment using either MulticoreParam (Linux, Mac) 
#' or SnowParam (Windows) with NCores using the package BiocParallel. 
#' @param ditherCounts whether to dither/jitter the counts, may be used for
#'    data with many ties, default is FALSE.
#' @param PropToUse proportion of genes closest to the slope mode used for
#'    the group fitting, default is set at .25. This number #' mainly affects
#'    speed.
#' @param Tau value of quantile for the quantile regression used to estimate
#'    gene-specific slopes (default is median, Tau = .5 ).
#' @param withinSample a vector of gene-specific features to correct counts
#'    within a sample prior to SCnorm. If NULL(default) then no correction will
#'    be performed. Examples of gene-specific features are GC content or gene
#'    length.
#' @param useSpikes whether to use spike-ins to perform across condition
#'    scaling (default=FALSE). Spike-ins must be stored in the SingleCellExperiment object 
#'    using isSpike() function. See vignette for example. 
#' @param useZerosToScale whether to use zeros when scaling across conditions (default=FALSE).
#'
#' @description Quantile regression is used to estimate the dependence of
#'    read counts on sequencing depth for every gene. Genes with similar
#'     dependence are then grouped, and a second quantile regression is used to
#'    estimate scale factors within each group. Within-group adjustment for
#'    sequencing depth is then performed using the estimated scale factors to
#'    provide normalized estimates of expression. If multiple conditions are
#'    provided, normalization is performed within condition and then
#'    normalized estimates are scaled between conditions. If withinSample=TRUE
#'    then the method from Risso et al. 2011 will be implemented.


#' @return List containing matrix of normalized expression (and optionally a
#'    matrix of size factors if reportSF = TRUE ).
#' @export


#' @importFrom parallel detectCores
#' @import graphics
#' @import grDevices
#' @import stats
#' @importFrom methods is as
#' @importFrom BiocParallel bplapply  
#' @importFrom BiocParallel register
#' @importFrom BiocParallel MulticoreParam
#' @importFrom BiocParallel bpparam
#' @importFrom parallel detectCores
#' @import SingleCellExperiment
#' @importFrom S4Vectors metadata
#' @import SummarizedExperiment
#' @importFrom BiocGenerics counts
#' @author Rhonda Bacher
#' @examples 
#'  
#'  data(ExampleSimSCData)
#'    Conditions = rep(c(1,2), each= 45)
#'    #DataNorm <- SCnorm(ExampleSimSCData, Conditions, 
#'    #FilterCellNum = 10)
#'    #str(DataNorm)

SCnorm <- function(Data=NULL, Conditions=NULL,
                    PrintProgressPlots=FALSE, reportSF=FALSE,
                    FilterCellNum=10, FilterExpression=0, Thresh=.1, 
                    K=NULL, NCores=NULL, ditherCounts=FALSE, 
                    PropToUse=.25, Tau=.5, 
                    withinSample=NULL, useSpikes=FALSE, useZerosToScale=FALSE) {
  
    if (is.null(Conditions)) {stop("Must supply conditions.")}
    if (FilterCellNum< 10)  {stop("Must set FilterCellNum >= 10.")}
        
    if (methods::is(Data, "SummarizedExperiment") | methods::is(Data, "SingleCellExperiment")) {
        Data <- methods::as(Data, "SingleCellExperiment")
      if (is.null(SummarizedExperiment::assayNames(Data)) || SummarizedExperiment::assayNames(Data)[1] != "counts") {
        message("Renaming the first element in assays(Data) to 'counts'")
          SummarizedExperiment::assayNames(Data)[1] <- "counts"
  
      if (is.null(colnames(counts(Data)))) {stop("Must supply sample/cell names!")}

      
      }
    }
    
      
    if (!(methods::is(Data, "SummarizedExperiment")) & !(methods::is(Data, "SingleCellExperiment"))) {
      Data <- data.matrix(Data)
      Data <- SingleCellExperiment(assays=list("counts"=Data))
     }
      
    Counts <- as.matrix(counts(Data))
    ## Checks
    
    if(any(colSums(Counts) == 0)) {stop("Data contains at least one 
            column will all zeros. Please remove these columns before 
            calling SCnorm(). Performing quality control on your data is highly recommended prior
            to running SCnorm!")}
      
    if(anyNA(Counts)) {stop("Data contains at least one value of NA. SCnorm is unsure how to proceed.")}
     
    if (is.null(NCores)) {NCores <- max(1, parallel::detectCores() - 1)}
    
    message(paste0("Setting up parallel computation using ", 
                      NCores, " cores" ))
    if (.Platform$OS.type == "windows") {
      prll=BiocParallel::SnowParam(workers=NCores)
      BiocParallel::register(BPPARAM = prll, default=TRUE)
    } else {   
      prll=BiocParallel::MulticoreParam(workers=NCores)
      BiocParallel::register(BPPARAM = prll, default=TRUE)
    }
    
    if (is.null(rownames(Counts))) {stop("Must supply gene/row names!")}
    if (is.null(colnames(Counts))) {stop("Must supply sample/cell names!")}

    if (ncol(Counts) != length(Conditions)) {stop("Number of columns in 
      expression matrix must match length of conditions vector!")}
    
    if (!is.null(K)) {message(paste0("SCnorm will normalize assuming ",
      K, " is the optimal number of groups. It is not advised to set this."))}
    

    if (ditherCounts == TRUE) {RNGkind("L'Ecuyer-CMRG");
      set.seed(1);message("Jittering values introduces some randomness, 
        for reproducibility set.seed(1) has been set.")}
      
    Levels <- unique(Conditions) # Number of conditions
  
  
    # Option to normalize within samples:
    if(!is.null(withinSample)) {
        if(length(withinSample) == nrow(Counts)) {
          message("Using loess method described in ''GC-Content Normalization 
          for RNA-Seq Data'', Risso et al. to perform within-sample 
          normalization. For other options see the original publication and 
          package EDASeq." )
        
        S4Vectors::metadata(Data)[["OriginalData"]] <- Data
        SummarizedExperiment::assays(Data)[["Counts"]] = apply(Counts, 2, 
                                                               correctWithin, 
                                                               correctFactor = withinSample)
        
        } else{
          message("Length of withinSample should match the number of 
            genes in Data!")
        }
    }
    names(Conditions) <- colnames(Data)
     
    DataList <- lapply(seq_along(Levels), function(x) {
        Counts[,which(Conditions == Levels[x])]}) # split conditions
    Genes <- rownames(Counts) 
    
    SeqDepthList <- lapply(seq_along(Levels), function(x) {
        colSums(Counts[,which(Conditions == Levels[x])])})
  
     NumZerosCellList <- lapply(seq_along(Levels), function(x) {
         colSums(DataList[[x]]!= 0) })
         
     if((sum(do.call(c, SeqDepthList) == 10000) / (nrow(Counts) * ncol(Counts))) >= .80) {
        warning("More than 80% of your data is zeros.  
        Check the quality of your data (remove low quality cells prior to running SCnorm). 
        You may need to adjust the filtering criteria for SCnorm using
        parameters FilterExpression and FilterCellNum. 
        It could also be the case that SCnorm is not be appropriate for your data (see vignette for details).")
      }
     if(any(do.call(c, NumZerosCellList) <= 100)) {
        warning("At least one cell/sample has less than 100 genes detected (non-zero). 
        Check the quality of your data or filtering criteria. 
        SCnorm may not be appropriate for your data (see vignette for details).")
      }
      
    message("Gene filter is applied within each condition.")
    GeneZerosList <- lapply(seq_along(Levels), function(x) {
         rowSums(DataList[[x]]!= 0) })
    MedExprList <- lapply(seq_along(Levels), function(x) {
        apply(DataList[[x]], 1, function(c) median(c[c != 0])) })
    GeneFilterList <- lapply(seq_along(Levels), function(x) {
        names(which(GeneZerosList[[x]] >= FilterCellNum & MedExprList[[x]] >= FilterExpression))})
  
    checkGeneFilter <- vapply(seq_along(Levels), function(x) {
             length(GeneFilterList[[x]])}, FUN.VALUE=numeric(1))
    if(any(checkGeneFilter < 100)) {
       stop("At least one condition has less then 100 genes that pass the specified filter. Check the quality of your data or filtering criteria. 
       SCnorm may not be appropriate for your data (see vignette for details).")
     }
       

    GeneFilterOUT <- lapply(seq_along(Levels), function(x) {
        names(which(GeneZerosList[[x]] < FilterCellNum | MedExprList[[x]] < FilterExpression))})
    names(GeneFilterOUT) <- paste0("GenesFilteredOutGroup", unique(Conditions))
  
 
    NM <- lapply(seq_along(Levels), function(x) {
        message(paste0(length(GeneFilterOUT[[x]]), 
           " genes in condition ", Levels[x]," will not be included in the normalization due to 
             the specified filter criteria."))})
  
    message("A list of these genes can be accessed in output, 
    see vignette for example.") 
    
    # Get median quantile regr. slopes.
    SlopesList <- lapply(seq_along(Levels), function(x) {
            getSlopes(Data = DataList[[x]][GeneFilterList[[x]],], 
                      SeqDepth = SeqDepthList[[x]], 
                      Tau=Tau, 
                      FilterCellNum=FilterCellNum, 
                      ditherCounts=ditherCounts)})
  
 
    # If k is NOT provided
    if (is.null(K)) {
        NormList <- lapply(seq_along(Levels), function(x) {
          normWrapper(Data = DataList[[x]], 
                      SeqDepth = SeqDepthList[[x]], 
                      Slopes = SlopesList[[x]],
                      CondNum = Levels[x], 
                      PrintProgressPlots = PrintProgressPlots,
                      PropToUse = PropToUse,
                      Tau = Tau, 
                      Thresh = Thresh, 
                      ditherCounts=ditherCounts)
      }) 
    }
    # If specific K then do:
    # If length of K is less than number of conditions, assume the same K.
    if (!is.null(K) ) {
      if (length(K) == length(Levels)) {
        NormList <- lapply(seq_along(Levels), function(x) {
          SCnormFit(Data = DataList[[x]], 
                    SeqDepth = SeqDepthList[[x]], Slopes = SlopesList[[x]],
                    K = K[x], PropToUse = PropToUse, 
                    ditherCounts=ditherCounts)
        })
      } else if (length(K) == 1) {
        K <- rep(K, length(Levels))
        NormList <- lapply(seq_along(Levels), function(x) {
          SCnormFit(Data = DataList[[x]], 
                    SeqDepth = SeqDepthList[[x]], Slopes = SlopesList[[x]],
                    K = K[x], PropToUse = PropToUse,
                    ditherCounts=ditherCounts)
        }) 
      } else (stop("Check that the specification of K is correct!"))
    }    
  

    if (length(Levels) > 1) {
    
      # Scaling
      message("Scaling data between conditions...")
      ScaledNormData <- scaleNormMultCont(NormData = NormList, 
                        OrigData = Data, 
                        Genes = Genes, useSpikes = useSpikes, 
                        useZerosToScale = useZerosToScale)
      names(ScaledNormData) <- c("NormalizedData", "ScaleFactors")
      
      NormDataFull <- ScaledNormData$NormalizedData
      ScaleFactorsFull <- ScaledNormData$ScaleFactors

      } else {
        NormDataFull <- NormList[[1]]$NormData
        ScaleFactorsFull <- NormList[[1]]$ScaleFactors
        }
    if(reportSF == FALSE) {
        ScaleFactorsFull <- NULL
        }
    
    
    # Return, To match SingleCellExperiment 
    SingleCellExperiment::normcounts(Data) <- NormDataFull[,names(Conditions)]
    S4Vectors::metadata(Data)[["ScaleFactors"]] <- ScaleFactorsFull[,names(Conditions)]
    S4Vectors::metadata(Data)[["GenesFilteredOut"]] <- GeneFilterOUT

  
    message("Done!")
  
return(Data)  
  
}


