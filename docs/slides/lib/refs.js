// Bibliography. Numbering follows `order` (order of first appearance in the talk).
export const refs = {
  fmm: {
    text: 'H. Cheng, L. Greengard, V. Rokhlin, “A Fast Adaptive Multipole Algorithm in Three Dimensions”, Journal of Computational Physics 155(2), 468–498, 1999. doi:10.1006/jcph.1999.6355',
    url: 'https://www.researchgate.net/publication/222474923_A_Fast_Adaptive_Multipole_Algorithm_in_Three_Dimensions',
  },
  kabadshow: {
    text: 'I. Kabadshow, “The Fast Multipole Method – Alternative Gradient Algorithm and Parallelization”, Diploma thesis, TU Chemnitz; Berichte des Forschungszentrums Jülich, Jül-4215, 2006.',
    url: 'http://hdl.handle.net/2128/485',
  },
  cornerstone: {
    text: 'S. Keller, A. Cavelan, R. Cabezón, L. Mayer, F. M. Ciorba, “Cornerstone: Octree Construction Algorithms for Scalable Particle Simulations”, PASC ’23, Article 18, 2023.',
    url: 'https://arxiv.org/abs/2307.06345',
  },
  benchmarking: {
    text: 'T. Hoefler, R. Belli, “Scientific Benchmarking of Parallel Computing Systems: Twelve Ways to Tell the Masses when Reporting Performance Results”, SC ’15, 2015. doi:10.1145/2807591.2807644',
    url: 'http://spcl.inf.ethz.ch/Teaching/2025-dphpc/hoefler-scientific-benchmarking.pdf',
  },
  fmsolvr: {
    text: 'A. Lengvenis, fmsolvr-cuda (FMM code base), Forschungszentrum Jülich.',
    url: 'https://code.fmsolvr.fz-juelich.de/a.lengvenis/fmsolvr-cuda',
  },
  kdlongest: {
    text: 'M. Dickerson, C. A. Duncan, M. T. Goodrich, “K-D Trees Are Better when Cut on the Longest Side”, ESA 2000, LNCS 1879, pp. 179–190, Springer, 2000.',
    url: 'https://web.cs.ucdavis.edu/~amenta/w07/kdlongest.pdf',
  },
  poirrier: {
    text: 'L. Poirrier, “An efficient space partitioning technique based on linear kd-trees for simulation of short-range interactions in particle methods”, preprint, 2009.',
    url: 'https://people.montefiore.uliege.be/poirrier/download/particle/poirrier-kdtree-pp2.pdf',
  },
}
// cited on slides first (order of appearance), then references listed only on the References slide
export const order = ['fmm', 'cornerstone', 'benchmarking', 'kdlongest', 'poirrier', 'fmsolvr', 'kabadshow']
export const num = id => order.indexOf(id) + 1
